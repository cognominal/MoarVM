#include "moar.h"

/* Check if we're currently taking heap snapshots. */
MVMint32 MVM_profile_heap_profiling(MVMThreadContext *tc) {
    return tc->instance->heap_snapshots != NULL;
}

/* Start heap profiling. */
void MVM_profile_heap_start(MVMThreadContext *tc, MVMObject *config) {
    tc->instance->heap_snapshots = MVM_calloc(1, sizeof(MVMHeapSnapshotCollection));
}

/* Grows storage if it's full, zeroing the extension. Assumes it's only being
 * grown for one more item. */
static void grow_storage(void **store, MVMuint64 *num, MVMuint64 *alloc, size_t size) {
    if (*num == *alloc) {
        *alloc = *alloc ? 2 * *alloc : 32;
        *store = MVM_realloc(*store, *alloc * size);
        memset(((char *)*store) + *num * size, 0, (*alloc - *num) * size);
    }
}

/* Get a string heap index for the specified C string, adding it if needed. */
 static MVMuint64 get_string_index(MVMThreadContext *tc, MVMHeapSnapshotState *ss,
                                   char *str, char is_const) {
     MVMuint64 i;

     /* Add a lookup hash here if it gets to be a hotspot. */
     MVMHeapSnapshotCollection *col = ss->col;
     for (i = 0; i < col->num_strings; i++)
        if (strcmp(col->strings[i], str) == 0)
            return i;

    grow_storage((void **)&(col->strings), &(col->num_strings),
        &(col->alloc_strings), sizeof(char *));
    grow_storage(&(col->strings_free), &(col->num_strings_free),
        &(col->alloc_strings_free), sizeof(char));
    col->strings[col->num_strings] = str;
    col->strings_free[col->num_strings] = !is_const;
    return col->num_strings++;
 }

/* Push a collectable to the list of work items, allocating space for it and
 * returning the collectable index. */
static MVMuint64 push_workitem(MVMThreadContext *tc, MVMHeapSnapshotState *ss,
                               MVMuint16 kind, void *target) {
    MVMHeapSnapshotWorkItem *wi;
    MVMuint64 col_idx;

    /* Mark space in collectables collection, and allocate an index. */
    grow_storage(&(ss->hs->collectables), &(ss->hs->num_collectables),
        &(ss->hs->alloc_collectables), sizeof(MVMHeapSnapshotCollectable));
    col_idx = ss->hs->num_collectables;
    ss->hs->num_collectables++;

    /* Add to the worklist. */
    grow_storage(&(ss->workitems), &(ss->num_workitems), &(ss->alloc_workitems),
        sizeof(MVMHeapSnapshotWorkItem));
    wi = &(ss->workitems[ss->num_workitems]);
    wi->kind = kind;
    wi->col_idx = col_idx;
    wi->target = NULL;
    ss->num_workitems++;

    return col_idx;
}

/* Pop a work item. */
static MVMHeapSnapshotWorkItem pop_workitem(MVMThreadContext *tc, MVMHeapSnapshotState *ss) {
    ss->num_workitems--;
    return ss->workitems[ss->num_workitems];
}

/* Sets the current reference "from" collectable. */
static void set_ref_from(MVMThreadContext *tc, MVMHeapSnapshotState *ss, MVMuint64 col_idx) {
    /* The references should be contiguous, so if this collectable already
     * has any, something's wrong. */
    if (ss->hs->collectables[col_idx].num_refs)
        MVM_panic(1, "Heap snapshot corruption: can not add non-contiguous refs");

    ss->ref_from = col_idx;
    ss->hs->collectables[col_idx].refs_start = ss->hs->num_references;
}

/* Adds a reference. */
static void add_reference(MVMThreadContext *tc, MVMHeapSnapshotState *ss, MVMuint16 ref_kind,
                          MVMuint64 index, MVMuint64 to) {
    /* Add to the references collection. */
    MVMHeapSnapshotReference *ref;
    MVMuint64 description = (index << MVM_SNAPSHOT_REF_KIND_BITS) | ref_kind;
    grow_storage(&(ss->hs->references), &(ss->hs->num_references),
        &(ss->hs->alloc_references), sizeof(MVMHeapSnapshotReference));
    ref = &(ss->hs->references[ss->hs->num_references]);
    ref->description = description;
    ref->collectable_index = to;
    ss->hs->num_references++;

    /* Increment collectable's number of references. */
    ss->hs->collectables[ss->ref_from].num_refs++;
}

/* Adds a reference with an integer description. */
// XXX

/* Adds a reference with a C string description. */
static void add_reference_cstr(MVMThreadContext *tc, MVMHeapSnapshotState *ss,
                               char *cstr,  MVMuint64 to) {
    MVMuint64 str_idx = get_string_index(tc, ss, cstr, 0);
    add_reference(tc, ss, MVM_SNAPSHOT_REF_KIND_STRING, str_idx, to);
}

/* Adds a reference with a constant C string description. */
static void add_reference_const_cstr(MVMThreadContext *tc, MVMHeapSnapshotState *ss,
                                     const char *cstr,  MVMuint64 to) {
    MVMuint64 str_idx = get_string_index(tc, ss, (char *)cstr, 1);
    add_reference(tc, ss, MVM_SNAPSHOT_REF_KIND_STRING, str_idx, to);
}

/* Adds a references with a string description. */
// XXX

/* Processes the work items, until we've none left. */
static void process_workitems(MVMThreadContext *tc, MVMHeapSnapshotState *ss) {
    while (ss->num_workitems > 0) {
        MVMHeapSnapshotWorkItem item = pop_workitem(tc, ss);
        MVMHeapSnapshotCollectable *col = &(ss->hs->collectables[item.col_idx]);

        col->kind = item.kind;
        set_ref_from(tc, ss, item.col_idx);

        switch (item.kind) {
            case MVM_SNAPSHOT_COL_KIND_PERM_ROOTS:
                /* XXX MVM_gc_root_add_permanents_to_worklist(tc, worklist); */
                break;
            case MVM_SNAPSHOT_COL_KIND_INSTANCE_ROOTS:
                /* XXX MVM_gc_root_add_instance_roots_to_worklist(tc, worklist); */
                break;
            case MVM_SNAPSHOT_COL_KIND_CSTACK_ROOTS:
                /* XXX MVM_gc_root_add_temps_to_worklist(tc, worklist); */
                break;
            case MVM_SNAPSHOT_COL_KIND_THREAD_ROOTS:
                /* XXX 
                 * MVM_gc_root_add_tc_roots_to_worklist(tc, worklist);
                 * MVM_gc_worklist_add_frame(tc, worklist, tc->cur_frame);
                 */
                 break;
            case MVM_SNAPSHOT_COL_KIND_ROOT:
                add_reference_const_cstr(tc, ss, "Permanent Roots",
                    push_workitem(tc, ss, MVM_SNAPSHOT_COL_KIND_PERM_ROOTS, NULL));
                add_reference_const_cstr(tc, ss, "VM Instance Roots",
                    push_workitem(tc, ss, MVM_SNAPSHOT_COL_KIND_INSTANCE_ROOTS, NULL));
                add_reference_const_cstr(tc, ss, "C Stack Roots",
                    push_workitem(tc, ss, MVM_SNAPSHOT_COL_KIND_CSTACK_ROOTS, NULL));
                add_reference_const_cstr(tc, ss, "Thread Roots",
                    push_workitem(tc, ss, MVM_SNAPSHOT_COL_KIND_THREAD_ROOTS, NULL));
                 break;
            default:
                MVM_panic(1, "Unknown heap snapshot worklist item kind %d", item.kind);
        }
    }
}

/* Drives the overall process of recording a snapshot of the heap. */
static void record_snapshot(MVMThreadContext *tc, MVMHeapSnapshotCollection *col, MVMHeapSnapshot *hs) {
    MVMuint64 perm_root_synth;

    /* Iinitialize state for taking a snapshot. */
    MVMHeapSnapshotState ss;
    memset(&ss, 0, sizeof(MVMHeapSnapshotState));
    ss.col = col;
    ss.hs = hs;

    /* We push the ultimate "root of roots" onto the worklist to get things
     * going, then set off on our merry way. */
    printf("Recording heap snapshot\n");
    push_workitem(tc, &ss, MVM_SNAPSHOT_COL_KIND_ROOT, NULL);
    process_workitems(tc, &ss);
    printf("Recording completed\n");

    /* Clean up temporary state. */
    MVM_free(ss.workitems);
}

/* Takes a snapshot of the heap, adding it to the current heap snapshot
 * collection. */
void MVM_profile_heap_take_snapshot(MVMThreadContext *tc) {
    if (MVM_profile_heap_profiling(tc)) {
        MVMHeapSnapshotCollection *col = tc->instance->heap_snapshots;
        grow_storage(&(col->snapshots), &(col->num_snapshots), &(col->alloc_snapshots),
            sizeof(MVMHeapSnapshot));
        record_snapshot(tc, col, &(col->snapshots[col->num_snapshots]));
        col->num_snapshots++;
    }
}

/* Frees all memory associated with the heap snapshot. */
static void destroy_heap_snapshot_collection(MVMThreadContext *tc) {
    MVMHeapSnapshotCollection *col = tc->instance->heap_snapshots;
    MVMuint64 i;

    for (i = 0; i < col->num_snapshots; i++) {
        MVMHeapSnapshot *hs = &(col->snapshots[i]);
        MVM_free(hs->collectables);
        MVM_free(hs->references);
    }
    MVM_free(col->snapshots);

    for (i = 0; i < col->num_strings; i++)
        if (col->strings_free[i])
            MVM_free(col->strings[i]);
    MVM_free(col->strings);

    /* XXX Free other pieces. */

    MVM_free(col);
    tc->instance->heap_snapshots = NULL;
}

/* Turns the collected data into MoarVM objects. */
#define vmstr(tc, cstr) MVM_string_utf8_decode(tc, tc->instance->VMString, cstr, strlen(cstr))
#define box_s(tc, str) MVM_repr_box_str(tc, MVM_hll_current(tc)->str_box_type, str)
MVMObject * string_heap_array(MVMThreadContext *tc, MVMHeapSnapshotCollection *col) {
    MVMObject *arr = MVM_repr_alloc_init(tc, tc->instance->boot_types.BOOTStrArray);
    MVMuint64 i;
    for (i = 0; i < col->num_strings; i++)
        MVM_repr_bind_pos_s(tc, arr, i, vmstr(tc, col->strings[i]));
    return arr;
}
MVMObject * collectables_str(MVMThreadContext *tc, MVMHeapSnapshot *s) {
    /* Produces ; separated sequences of:
     *   kind,type_or_frame_index,collectable_size,unmanaged_size,refs_start,num_refs
     * All of which are integers.
     */
     MVMObject *result;
     size_t buffer_size = 20 * s->num_references;
     size_t buffer_pos  = 0;
     char *buffer       = MVM_malloc(buffer_size);

     MVMuint64 i;
     for (i = 0; i < s->num_references; i++) {
         char tmp[256];
         size_t item_chars = snprintf(tmp, 256,
            "%"PRId16",%"PRId32",%"PRId16",%"PRId64",%"PRId32",%"PRId64";",
            s->collectables[i].kind,
            s->collectables[i].type_or_frame_index,
            s->collectables[i].collectable_size,
            s->collectables[i].unmanaged_size,
            s->collectables[i].refs_start,
            s->collectables[i].num_refs);
         if (item_chars < 0)
             MVM_panic(1, "Failed to save collectable in heap snapshot");
         if (buffer_pos + item_chars >= buffer_size) {
             buffer_size += 4096;
             buffer = MVM_realloc(buffer, buffer_size);
         }
         memcpy(buffer + buffer_pos, tmp, item_chars);
         buffer_pos += item_chars;
     }
     buffer[buffer_pos] = 0;

     result = box_s(tc, vmstr(tc, buffer));
     MVM_free(buffer);
     return result;
}
MVMObject * references_str(MVMThreadContext *tc, MVMHeapSnapshot *s) {
    /* Produces ; separated sequences of:
     *   kind,idx,to
     * All of which are integers.
     */
    MVMObject *result;
    size_t buffer_size = 10 * s->num_references;
    size_t buffer_pos  = 0;
    char *buffer       = MVM_malloc(buffer_size);

    MVMuint64 i;
    for (i = 0; i < s->num_references; i++) {
        char tmp[128];
        size_t item_chars = snprintf(tmp, 128, "%lu,%lu,%lu;",
            s->references[i].description & ((1 << MVM_SNAPSHOT_REF_KIND_BITS) - 1),
            s->references[i].description >> MVM_SNAPSHOT_REF_KIND_BITS,
            s->references[i].collectable_index);
        if (item_chars < 0)
            MVM_panic(1, "Failed to save reference in heap snapshot");
        if (buffer_pos + item_chars >= buffer_size) {
            buffer_size += 4096;
            buffer = MVM_realloc(buffer, buffer_size);
        }
        memcpy(buffer + buffer_pos, tmp, item_chars);
        buffer_pos += item_chars;
    }
    buffer[buffer_pos] = 0;

    result = box_s(tc, vmstr(tc, buffer));
    MVM_free(buffer);
    return result;
}
MVMObject * snapshot_to_mvm_object(MVMThreadContext *tc, MVMHeapSnapshot *s) {
    MVMObject *snapshot = MVM_repr_alloc_init(tc, MVM_hll_current(tc)->slurpy_hash_type);
    MVM_repr_bind_key_o(tc, snapshot, vmstr(tc, "collectables"),
        collectables_str(tc, s));
    MVM_repr_bind_key_o(tc, snapshot, vmstr(tc, "references"),
        references_str(tc, s));
    return snapshot;
}
MVMObject * snapshots_to_mvm_objects(MVMThreadContext *tc, MVMHeapSnapshotCollection *col) {
    MVMObject *arr = MVM_repr_alloc_init(tc, MVM_hll_current(tc)->slurpy_array_type);
    MVMuint64 i;
    for (i = 0; i < col->num_snapshots; i++)
        MVM_repr_bind_pos_o(tc, arr, i,
            snapshot_to_mvm_object(tc, &(col->snapshots[i])));
    return arr;
}
MVMObject * collection_to_mvm_objects(MVMThreadContext *tc, MVMHeapSnapshotCollection *col) {
    MVMObject *results;

    /* Allocate in gen2, so as not to trigger GC. */
    MVM_gc_allocate_gen2_default_set(tc);

    /* Top-level results is a hash. */
    results = MVM_repr_alloc_init(tc, MVM_hll_current(tc)->slurpy_hash_type);
    MVM_repr_bind_key_o(tc, results, vmstr(tc, "strings"),
        string_heap_array(tc, col));
    MVM_repr_bind_key_o(tc, results, vmstr(tc, "snapshots"),
        snapshots_to_mvm_objects(tc, col));

    /* Switch off gen2 allocations now we're done. */
    MVM_gc_allocate_gen2_default_clear(tc);

    return results;
}

/* Finishes heap profiling, getting the data. */
MVMObject * MVM_profile_heap_end(MVMThreadContext *tc) {
    MVMObject *dataset = collection_to_mvm_objects(tc, tc->instance->heap_snapshots);
    destroy_heap_snapshot_collection(tc);
    return dataset;
}
