#!/usr/bin/env perl
package template_compiler;
use v5.10;
use strict;
use warnings FATAL => 'all';

use Getopt::Long;
use File::Spec;
use Scalar::Util qw(looks_like_number refaddr reftype);
use Carp qw(confess);

# use my libs
use FindBin;
use lib File::Spec->catdir($FindBin::Bin, 'lib');

use sexpr;
use expr_ops;
use oplist;



# Input:
#   (load (addr pargs $1))
# Output
#   template: (MVM_JIT_ADDR, MVM_JIT_PARGS, 1, MVM_JIT_LOAD, 0)
#   length: 5, root: 3 "..f..l"


# options to compile
my %OPTIONS = (
    prefix => 'MVM_JIT_',
    include => 1,
);
GetOptions(\%OPTIONS, qw(prefix=s list=s input=s output=s include! test));

my ($PREFIX, $OPLIST) = @OPTIONS{'prefix', 'oplist'};
if ($OPTIONS{output}) {
    close( STDOUT ) or die $!;
    open( STDOUT, '>', $OPTIONS{output} ) or die $!;
}

if ($OPTIONS{input} //= shift @ARGV) {
    close( STDIN );
    open( STDIN, '<', $OPTIONS{input} ) or die $!;
}

END {
    close STDOUT;
    if ($? && $OPTIONS{output}) {
        unlink $OPTIONS{output};
    }
}

# Template check tables

# Expected result type
my %OPERATOR_TYPES = (
    (map { $_ => 'void' } qw(store store_num discard dov when ifv branch mark callv guard)),
    (map { $_ => 'flag' } qw(lt le eq ne ge gt nz zr all any)),
    (map { $_ => 'num' }  qw(const_num load_num calln)),
    (map { $_ => '?' }    qw(if copy do add sub mul)),
    qw(arglist) x 2,
    qw(carg) x 2,
);


# Expected type of operands
my %OPERAND_TYPES = (
    flagval => 'flag',
    all => 'flag',
    any => 'flag',
    copy => '?',
    do => 'void,?',
    dov => 'void',
    when => 'flag,void',
    if => 'flag,?,?',
    ifv => 'flag,void,void',
    call => 'reg,arglist',
    calln => 'reg,arglist',
    callv => 'reg,arglist',
    arglist => 'carg',
    carg => '?',
    store => 'reg,?',
    guard => 'void',
    # anything on numbers is polymorphic,
    # because the output type is the input type
    map(($_ => '?'), qw(lt le eq ne ge gt nz zr add sub mul)),
);

# which list item is the size
my %OP_SIZE_PARAM = (
    load => 2,
    load_num => 2,
    store => 3,
    store_num => 3,
    call => 3,
    const => 2,
    cast => 2,
);

# Map MoarVM types to expr types
my %MOAR_TYPES = (
    num32 => 'num',
    num64 => 'num',
    '`1'  => '?',
);

my %VARIADIC = map { $_ => 1 } grep $EXPR_OPS{$_}{num_operands} < 0, keys %EXPR_OPS;

# Opcode helpers
sub operand_direction {
    my ($opcode) = @_;
    my @operands = @{$OPLIST{$opcode}{operands}};
    my @direction;
    while (@operands) {
        my ($direction, $type) = splice @operands, 0, 2;
        push @direction, $direction;
    }
    return @direction;
}

sub operand_types {
    my ($opcode) = @_;
    my @operands = @{$OPLIST{$opcode}{operands}};
    my @type;
    while (@operands) {
        my ($direction, $type) = splice @operands, 0, 2;
        push @type, $type;
    }
    return @type;
}

sub output_operand {
    my ($opcode) = @_;
    my @operands = @{$OPLIST{$opcode}{operands}};
    while (@operands) {
        my ($mode,$type) = splice @operands, 0, 2;
        return $type if $mode eq 'w';
    }
    return;
}

sub moar_operands {
    my ($opcode) = @_;
    my @types = operand_types($opcode);
    push @types, @types if ($opcode =~ m/^(inc|dec)_[iu]$/); # hack
    return map {; "\$$_" => $MOAR_TYPES{$types[$_]} || 'reg' } (0..$#types);
}

# Need a global constant table
my %CONSTANTS;

sub compile_template {
    my ($expr, $opcode, $operands) = @_;
    my $compiler = +{
        expr  => {},
        tmpl  => [],
        desc  => [],
        opcode => $opcode,
        operands => $operands,
        constants => \%CONSTANTS,
    };
    my ($mode, $root) = compile_expression($compiler, $expr);
    die "Invalid template!" unless $mode eq 'l'; # top should be a simple expression
    return {
        root => $root,
        template => $compiler->{tmpl},
        desc => join('', @{$compiler->{desc}}),
    };
}

sub is_arrayref {
    defined(reftype($_[0])) && reftype($_[0]) eq 'ARRAY';
}

# Eager linking of declarations is what keeps them hygienic in the face of macros
# If we eliminate names as soon as we can, they'll have no opportunity to clash.
sub link_declarations {
    my ($expr, %env) = @_;
    my ($operator, @operands) = @$expr;
    if ($operator eq 'let:') {
        my ($declarations, @expressions) = @operands;
        my @definitions;
        for my $declaration (@$declarations) {
            my ($name, $definition) = @$declaration;
            link_declarations($definition, %env);
            check_type(expr_type($definition, \%env), '?', $operator);
            $env{$name} = $definition;
            push @definitions, ['discard', $definition];
        }
        for my $expr (@expressions) {
            link_declarations($expr, %env);
        }
        my $type = expr_type($expressions[$#expressions], \%env);
        # replace statement with DO/DOV
        @$expr = ($type eq 'void' ? 'dov' : 'do', @definitions, @expressions);
    } else {
        for my $i (1..$#$expr) {
            my $operand = $expr->[$i];
            if (is_arrayref($operand) and @$operand) {
                link_declarations($operand, %env);
            } elsif ($operand =~ m/\$(\w+)/) {
                next if looks_like_number($1);
                die "Invalid name $operand" unless exists $env{$operand};
                $expr->[$i] = $env{$operand};
            }
        }
    }
    return $expr;
}

sub apply_macros {
    my ($expr, $macros) = @_;
    # empty lists can occur for instance with macros without arguments
    return unless is_arrayref($expr) and @$expr;

    my ($operator, @operands) = @$expr;
    for my $element (@operands) {
        if (is_arrayref($element)) {
            apply_macros($element, $macros);
        }
    }

    if ($operator =~ m/^\^/) {
        # looks like a macro
        if (my $macro = $macros->{$operator}) {
            my ($params, $structure) = @$macro;
            die sprintf("Macro %s needs %d params, got %d",
                        $operator, $#$expr, 0+@{$params})
                unless $#$expr == @{$params};
            my %bind; @bind{@$params} = @$expr[1..$#$expr];
            my $instance = expand_macro($structure, \%bind, {});
            @$expr = @$instance;
        } else {
            die "Tried to instantiate undefined macro $operator";
        }
    }
    return $expr;
}

# Makes a copy of the macro with bindings replaced
sub expand_macro {
    my ($macro, $bind, $sub) = @_;
    my @result;
    for my $element (@$macro) {
        if (is_arrayref($element)) {
            # Reuse substituted instance to maintain link identity
            my $instance = $sub->{refaddr($element)} ||=
                expand_macro($element, $bind, $sub);
            push @result, $instance;
        } elsif ($element =~ m/^,/) {
            if (defined $bind->{$element}) {
                push @result, $bind->{$element};
            } else {
                die "Unmatched macro substitution: $element";
            }
        } else {
            push @result, $element;
        }
    }
    return \@result;
}

sub expr_type {
    my ($expr, $env) = @_;
    # operand value; a reference (\$0) is always a reg
    return $1 ? 'reg' : $env->{$2} || confess "$2 is not declared"
        if ($expr =~ m/^(\\?)(\$\w+)$/);
    my ($operator, @operands) = @$expr;
    die "Expected operator but got $operator" if $operator =~ m/(^&)|(:$)/;
    # try to resolve polymorphic operators
    if ($operator =~ /ifv?/) {
        my ($flag, $left, $right) = map expr_type($_, $env), @operands;
        check_type($flag, 'flag', $operator); # must be a flag
        return check_type($left eq '?' ? ($right, $left) : ($left, $right),
                          $operator); # should be equivalent
    } elsif ($operator eq 'do') {
        return expr_type($operands[$#operands], $env);
    } elsif ($operator eq 'copy') {
        return expr_type($operands[0], $env);
    } else {
        my $type = $OPERATOR_TYPES{$operator} || 'reg';
        if ($type eq '?') {
            my $subtype = expr_type($operands[0], $env);
            for my $i (1..$#operands) {
                check_type(expr_type($operands[$i], $env), $subtype, $operator);
            }
            return $subtype;
        }
        return $type;
    }
}

sub check_type {
    my ($got, $want, $why) = @_;
    return $got if $want eq $got;
    return $got if $want eq '?' and $got =~ m/reg|num/;
    confess "$why: Got $got wanted $want";
}

sub compile_expression {
    my ($compiler, $expr) = @_;

    return 'l' => $compiler->{expr}{refaddr($expr)}
        if exists $compiler->{expr}{refaddr($expr)};

    my ($operator, @operands) = @$expr;

    die "Expected expression but got macro" if $operator =~ m/^&/;
    die "Unknown operator $operator" unless my $info = $EXPR_OPS{$operator};

    my $num_operands = $VARIADIC{$operator} ? @operands : $info->{num_operands};
    my $num_params = $info->{num_params};

    die "Expected $num_operands operands and $num_params params for $operator, got " . scalar @operands
        if $num_operands + $num_params != @operands;

    # large constants are treated specially
    if ($operator =~ m/^const_(ptr|large)$/) {
        my ($value, $size) = @operands;
        return 'l' => emit($compiler,
                           compile_operator($compiler, $operator, 0),
                           compile_constant($compiler, $value),
                           defined $size ? ('.' => $size) : ());
    }

    # match up types
    my @types = split /,/, ($OPERAND_TYPES{$operator} // 'reg');
    if (@types < $num_operands) {
        if (@types == 1) {
            @types = (@types) x $num_operands;
        } elsif (@types == 2) {
            @types = (($types[0]) x ($num_operands-1), $types[1]);
        } else {
            die "Can't match up types";
        }
    }

    my @code = compile_operator($compiler, $operator, $num_operands);

    my $i = 0;
    for (; $i < $num_operands; $i++) {
        check_type(expr_type($operands[$i], $compiler->{operands}), $types[$i],
                   $operator);
        push @code, compile_operand($compiler, $operands[$i]);
    }

    # check size parameter if any
    if (my $param = $OP_SIZE_PARAM{$operator}) {
        my $size = $operands[$param - 1];
        die "Expected size parameter" unless
            # macro, number or bareword-ending-with-size
            ((is_arrayref($size) && $size->[0] =~ m/^&/) ||
             looks_like_number($size) || $size =~ m/_sz$/);
    }
    for (; $i < $num_operands + $num_params; $i++) {
        push @code, compile_parameter($compiler, $operands[$i]);
    }
    my $node = emit($compiler, @code);
    $compiler->{expr}{refaddr($expr)} = $node;
    return 'l' => $node;
}

sub compile_constant {
    my ($compiler, $value, $size) = @_;
    (undef, $value) = compile_macro($compiler, $value) if is_arrayref($value);
    my $constants = $compiler->{constants};
    my $const_nr = ($constants->{$value} = exists $constants->{$value} ?
                        $constants->{$value} : scalar keys %$constants);
    return 'c' => $const_nr;
}

sub compile_operand {
    my ($compiler, $expr) = @_;
    if (is_arrayref($expr)) {
        compile_expression($compiler, $expr);
    } else {
        compile_reference($compiler, $expr);
    }
}

sub compile_reference {
    my ($compiler, $expr) = @_;
    die "Expected reference got $expr" unless
        my ($ref, $name) = $expr =~ m/^(\\?)\$(\w+)/;
    if (looks_like_number($name)) {
        my $opcode = $compiler->{opcode};
        # special case for dec_i/inc_i
        return 'i' => $name if $opcode =~ m/^(dec|inc)_i$/ and $name <= 1;
        my @direction = operand_direction($opcode);
        die "Invalid operand reference $expr for $opcode"
            unless $name >= 0 && $name < @direction;
        if ($direction[$name] eq 'w') {
            die "Require reference for write operand \$$name ($opcode)"
                unless $ref;
        } else {
            die "Operand \$$name of $opcode is not a reference" if $ref;
        }
        return 'i' => $name;
    } else {
        die "Undefined named reference $expr"
            unless defined (my $ref = $compiler->{env}{$expr});
        return 'l' => $ref;
    }
}

sub compile_parameter {
    my ($compiler, $expr) = @_;
    if (is_arrayref($expr)) {
        return compile_macro($compiler, $expr);
    } elsif (looks_like_number($expr)) {
        return '.' => $expr;
    } else {
        return compile_bareword($compiler, $expr);
    }
}

sub compile_macro {
    my ($compiler, $expr) = @_;
    my ($name, @parameters) = @$expr;
    die "Expected a macro expression, got $name"
        unless my ($macro) = $name =~ m/^&(\w+)/;
    return '.' => sprintf('%s(%s)', $macro, join(', ', @parameters));
}

sub compile_operator {
    my ($compiler, $expr, $num_operands) = @_;
    die "$expr is not a valid operator" unless exists $EXPR_OPS{$expr};
    die "Invalid size $num_operands" unless looks_like_number($num_operands);
    return ('n' => $PREFIX . uc($expr), 's' => $num_operands);
}

sub compile_bareword {
    my ($compiler, $expr) = @_;
    return '.' => $PREFIX . uc($expr);
}

sub emit {
    my ($compiler, @code) = @_;
    my $node = @{$compiler->{tmpl}};
    while (@code) {
        push @{$compiler->{desc}}, shift @code;
        push @{$compiler->{tmpl}}, shift @code;
    }
    return $node;
}


sub test {
    # single let:
    my $expr = sexpr_decode('(let: (($foo (copy $1))) (load $foo 8))');
    link_declarations($expr);
    die "Linking invalid" unless $expr->[1][1] == $expr->[2][1];

    # nested let: with left-to-right declarations
    $expr = sexpr_decode('(let: (($foo (const 1 1)) ($bar (add $foo $foo))) ' .
                             '(let: (($foo (sub $bar (const 1 1)))) (copy $foo)))');
    link_declarations($expr);

    # forward declaration
    die "Linking invalid" unless $expr->[1][1] == $expr->[2][1][1] and
        $expr->[1][1] == $expr->[2][1][2];
    # inner declaration
    die "Linking invalid" unless $expr->[2][1] == $expr->[3][1][1][1] # do -> discard -> sub -> $bar
        and $expr->[3][1][1] == $expr->[3][2][1]; # do -> discard -> sub == do -> copy -> $foo

    $expr = sexpr_decode('(let: (($obj (load $1))) (^foo $obj))');
    my $macro = sexpr_decode('((,foo) (let: (($obj (addr ,foo 8))) (add ,foo $obj)))');
    link_declarations($macro);
    link_declarations($expr);
    apply_macros($expr, { '^foo' => $macro });

    # outer (let:)
    die "Linking invalid" unless $expr->[1][1] == $expr->[2][2][1];
    # macro (let:)
    die "Linking invalid" unless $expr->[2][1][1] == $expr->[2][2][2];

    printf STDERR "Linking and macro application OK\n";
    exit;
}

test if $OPTIONS{test};


my %SEEN;

sub parse_file {
    my ($fh, $macros) = @_;
    my (@templates, %info);
    my $parser = sexpr->parser($fh);
    while (my $tree = $parser->parse) {
        my $keyword = shift @$tree;
        if ($keyword eq 'macro:') {
            my ($name, $binding, $macro) = @$tree;
            die "Redeclaration of macro $name" if exists $macros->{$name};

            $macro = link_declarations($macro);
            $macro = apply_macros($macro, $macros);

            $macros->{$name} = [ $binding, $macro ];
        } elsif ($keyword eq 'template:') {
            my $opcode   = shift @$tree;
            my $template = shift @$tree;

            my $destructive = 0+!!($opcode =~ s/!$//);
            die "Opcode '$opcode' unknown" unless exists $OPLIST{$opcode};
            die "Opcode '$opcode' redefined" if exists $info{$opcode};

            my $output  = output_operand($opcode);

            die "No write operand for destructive template $opcode"
                if $destructive && !$output;
            my $operands = +{ moar_operands($opcode) };

            $template = link_declarations($template, %$operands);
            $template = apply_macros($template, $macros);


            my $expr_type = expr_type($template, $operands);

            my $output_type = ($destructive || !$output) ?
                'void' : ($MOAR_TYPES{$output} || 'reg');
            check_type($expr_type, $output_type, $opcode);

            my $compiled = compile_template($template, $opcode, $operands);

            $info{$opcode} = {
                idx => scalar @templates,
                info => $compiled->{desc},
                root => $compiled->{root},
                len => length($compiled->{desc}),
                flags => $destructive,
            };
            push @templates, @{$compiled->{template}};
        } elsif ($keyword eq 'include:') {
            my $file = shift @$tree;
            $file =~ s/^"|"$//g;

            if ($SEEN{$file}++) {
                warn "$file already included";
                next;
            }

            open( my $handle, '<', $file ) or die $!;
            my ($inc_templates, $inc_info) = parse_file($handle, $macros);
            close( $handle ) or die $!;
            die "Template redeclared in include" if grep $info{$_}, keys %$inc_info;

            # merge templates into including file
            $_->{idx} += @templates for values %$inc_info;
            $info{keys %$inc_info} = values %$inc_info;
            push @templates, @$inc_templates;

        } else {
            die "I don't know what to do with '$keyword' ";
        }
    }
    return \(@templates, %info);
}


my ($templates, $info) = parse_file(\*STDIN, {});
close( STDIN ) or die $!;

# write a c output header file.
print <<"HEADER";
/* FILE AUTOGENERATED BY $0. DO NOT EDIT.
 * Defines tables for expression templates. */
HEADER
my $i = 0;
print "static const MVMint32 MVM_jit_expr_templates[] = {\n    ";
for (@$templates) {
    $i += length($_) + 2;
    if ($i > 75) {
        print "\n    ";
        $i = length($_) + 2;
    }
    print "$_,";
}
print "\n};\n";
print "static const MVMJitExprTemplate MVM_jit_expr_template_info[] = {\n";
for my $opcode (@OPLIST) {
    my ($name) = @$opcode;
    if (defined($info->{$name})) {
        my $td = $info->{$name};
        printf '    { MVM_jit_expr_templates + %d, "%s", %d, %d, %d },%s',
          $td->{idx}, $td->{info}, $td->{len}, $td->{root}, $td->{flags}, "\n";
    } else {
        print "    { NULL, NULL, -1, 0 },\n";
    }
}
print "};\n";

my @constants; @constants[values %CONSTANTS] = keys %CONSTANTS;
print "static const void* MVM_jit_expr_template_constants[] = {\n";
print "    $_,\n" for @constants;
print "};\n";

printf <<'FOOTER', scalar @OPLIST;
static const MVMJitExprTemplate * MVM_jit_get_template_for_opcode(MVMuint16 opcode) {
    if (opcode >= %d) return NULL;
    if (MVM_jit_expr_template_info[opcode].len < 0) return NULL;
    return &MVM_jit_expr_template_info[opcode];
}
FOOTER
