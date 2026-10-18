// Fragment output arrays, split for MoltenVK.
//
// The host runs the guest's Vulkan on MoltenVK, which turns SPIR-V into Metal
// (SPIRV-Cross) when it builds a pipeline, and leaves out the fragment
// outputs the subpass has no colour attachment for. An output array such as
// ANGLE's gl_FragData[8] at location 0 stays in Metal's output struct as one
// member per element even when the subpass has a single attachment; the
// members past the attachments lose their [[color(n)]] attribute, Metal
// refuses the function ("'color' attribute must be made explicit") and
// vkCreateGraphicsPipelines fails (VK_ERROR_INITIALIZATION_FAILED). Separate
// outputs are left out one by one, so each element gets its own:
//
// - the array becomes a Private variable of the same type, so every load,
//   store and access chain into it, with any index, works as before;
// - each element gets an Output variable at its own location, with the
//   array's other decorations (Component, Index, RelaxedPrecision);
// - before each OpReturn of the fragment entry point the elements are copied
//   to their outputs (OpKill and OpTerminateInvocation write none anyway).
//
// A module the layer does not fully understand (a pointer into the array
// passed to a function or through OpPhi, decoration groups, debug info about
// the array, ...) stays as it is.
#include "frag_outputs.h"

#include <stdbool.h>
#include <stdlib.h>

enum { MAGIC = 0x07230203, VERSION_1_4 = 0x00010400, MAX_BOUND = 0x3fffff };

enum {
    OP_LINE = 8,
    OP_EXT_INST = 12,
    OP_ENTRY_POINT = 15,
    OP_TYPE_INT = 21,
    OP_TYPE_FLOAT = 22,
    OP_TYPE_VECTOR = 23,
    OP_TYPE_ARRAY = 28,
    OP_TYPE_POINTER = 32,
    OP_CONSTANT = 43,
    OP_FUNCTION = 54,
    OP_VARIABLE = 59,
    OP_LOAD = 61,
    OP_STORE = 62,
    OP_COPY_MEMORY = 63,
    OP_COPY_MEMORY_SIZED = 64,
    OP_ACCESS_CHAIN = 65,
    OP_IN_BOUNDS_ACCESS_CHAIN = 66,
    OP_DECORATE = 71,
    OP_GROUP_DECORATE = 74,
    OP_VECTOR_SHUFFLE = 79,
    OP_COMPOSITE_EXTRACT = 81,
    OP_COMPOSITE_INSERT = 82,
    OP_COPY_OBJECT = 83,
    OP_LOOP_MERGE = 246,
    OP_SELECTION_MERGE = 247,
    OP_SWITCH = 251,
    OP_RETURN = 253,
    OP_DECORATE_ID = 332,
};
enum { OUTPUT = 3, PRIVATE = 6 };
enum { RELAXED_PRECISION = 0, BUILT_IN = 11, LOCATION = 30 };
enum { FRAGMENT = 4 };

enum { MAX_SPLITS = 32, MAX_ELEMENTS = 32, MAX_ENTRIES = 16 };
enum { TRACK_ARRAY = 1, TRACK_POINTER = 2 };

typedef struct {
    size_t declaration; // its OpVariable
    uint32_t var, array, element, count, location;
    uint32_t shadow_type;  // Private pointer to the array
    uint32_t output_type;  // Output pointer to an element
    uint32_t first_output; // element i's output is first_output + i
    bool located, listed, rejected, decorated;
} Split;

typedef struct {
    uint32_t id, storage, pointee;
} Pointer;

typedef struct {
    const uint32_t* w;
    size_t n;
    size_t functions; // the first OpFunction
    uint32_t version, bound, next_id;
    uint32_t* def;    // where each type, constant and module-level variable is declared
    uint8_t* tracked; // TRACK_ARRAY for a split array, TRACK_POINTER for a pointer into one
    Split splits[MAX_SPLITS];
    uint32_t split_count;
    struct {
        uint32_t function, splits; // a fragment entry point's function, and the splits it lists (bits)
    } entries[MAX_ENTRIES];
    uint32_t entry_count;
    Pointer* pointers; // the module's pointer types, then the ones the layer adds
    size_t pointer_count, pointer_capacity, module_pointers;
    uint32_t* out;
    size_t out_count, out_capacity;
    bool out_failed;
} Module;

static uint32_t opcode(const Module* m, size_t pos) { return m->w[pos] & 0xffff; }
static uint32_t length(const Module* m, size_t pos) { return m->w[pos] >> 16; }

// Where `id` is declared when that is an `op`, or 0.
static size_t def_of(const Module* m, uint32_t id, uint32_t op) {
    if (id == 0 || id >= m->bound) return 0;
    size_t pos = m->def[id];
    return pos && opcode(m, pos) == op ? pos : 0;
}

static bool tracked(const Module* m, uint32_t id) { return id < m->bound && m->tracked[id]; }

static Split* split_of(Module* m, uint32_t id) {
    for (uint32_t i = 0; i < m->split_count; i++) {
        if (m->splits[i].var == id) return &m->splits[i];
    }
    return NULL;
}

// What a colour output can hold: a 16- or 32-bit scalar, or a vector of them.
static bool colour_type(const Module* m, uint32_t type) {
    size_t vector = def_of(m, type, OP_TYPE_VECTOR);
    if (vector) type = m->w[vector + 2];
    size_t scalar = def_of(m, type, OP_TYPE_FLOAT);
    if (!scalar) scalar = def_of(m, type, OP_TYPE_INT);
    return scalar && (m->w[scalar + 2] == 16 || m->w[scalar + 2] == 32);
}

// The value of a 32-bit integer OpConstant, or 0.
static uint32_t constant_u32(const Module* m, uint32_t id) {
    size_t constant = def_of(m, id, OP_CONSTANT);
    if (!constant || length(m, constant) != 4) return 0;
    size_t type = def_of(m, m->w[constant + 1], OP_TYPE_INT);
    return type && m->w[type + 2] == 32 ? m->w[constant + 3] : 0;
}

// Words of the literal string at `w` (nul-terminated, padded), or 0 when it does not end.
static size_t string_words(const uint32_t* w, size_t available) {
    for (size_t i = 0; i < available; i++) {
        uint32_t x = w[i];
        if (!(x & 0xff) || !(x & 0xff00) || !(x & 0xff0000) || !(x & 0xff000000)) return i + 1;
    }
    return 0;
}

static bool add_pointer(Module* m, uint32_t id, uint32_t storage, uint32_t pointee) {
    if (m->pointer_count == m->pointer_capacity) {
        size_t capacity = m->pointer_capacity ? m->pointer_capacity * 2 : 32;
        Pointer* grown = realloc(m->pointers, capacity * sizeof *grown);
        if (!grown) return false;
        m->pointers = grown;
        m->pointer_capacity = capacity;
    }
    m->pointers[m->pointer_count++] = (Pointer){id, storage, pointee};
    return true;
}

static uint32_t find_pointer(const Module* m, uint32_t storage, uint32_t pointee) {
    for (size_t i = 0; i < m->pointer_count; i++) {
        if (m->pointers[i].storage == storage && m->pointers[i].pointee == pointee) return m->pointers[i].id;
    }
    return 0;
}

// The module's pointer type, or one the layer declares; 0 when out of memory.
static uint32_t pointer_to(Module* m, uint32_t storage, uint32_t pointee) {
    uint32_t id = find_pointer(m, storage, pointee);
    if (id) return id;
    id = m->next_id++;
    return add_pointer(m, id, storage, pointee) ? id : 0;
}

// MARK: Finding the arrays

static bool find_splits(Module* m) {
    const uint32_t* w = m->w;
    for (size_t pos = 5; pos < m->functions; pos += length(m, pos)) {
        uint32_t op = opcode(m, pos), len = length(m, pos), id = 0;
        switch (op) {
        case OP_TYPE_INT:
        case OP_TYPE_VECTOR:
        case OP_TYPE_ARRAY:
        case OP_TYPE_POINTER:
            if (len >= 4) id = w[pos + 1];
            break;
        case OP_TYPE_FLOAT:
            if (len >= 3) id = w[pos + 1];
            break;
        case OP_CONSTANT:
        case OP_VARIABLE:
            if (len >= 4) id = w[pos + 2];
            break;
        }
        if (id && id < m->bound) m->def[id] = (uint32_t)pos;
        if (op == OP_TYPE_POINTER && len >= 4 && !add_pointer(m, w[pos + 1], w[pos + 2], w[pos + 3])) return false;
    }
    m->module_pointers = m->pointer_count;

    // Output arrays of colours.
    for (size_t pos = 5; pos < m->functions; pos += length(m, pos)) {
        if (opcode(m, pos) != OP_VARIABLE || length(m, pos) < 4 || w[pos + 3] != OUTPUT || w[pos + 2] >= m->bound) continue;
        size_t pointer = def_of(m, w[pos + 1], OP_TYPE_POINTER);
        size_t array = pointer && w[pointer + 2] == OUTPUT ? def_of(m, w[pointer + 3], OP_TYPE_ARRAY) : 0;
        if (!array) continue;
        uint32_t count = constant_u32(m, w[array + 3]);
        if (count < 2 || count > MAX_ELEMENTS || !colour_type(m, w[array + 2])) continue;
        if (m->split_count == MAX_SPLITS) return false;
        m->splits[m->split_count++] =
            (Split){.declaration = pos, .var = w[pos + 2], .array = w[array + 1], .element = w[array + 2], .count = count};
    }
    if (!m->split_count) return false;

    // With a location, not built in, only in fragment entry points, and
    // nothing else at module level that refers to them.
    for (size_t pos = 5; pos < m->functions; pos += length(m, pos)) {
        uint32_t op = opcode(m, pos), len = length(m, pos);
        Split* split;
        switch (op) {
        case OP_ENTRY_POINT: {
            size_t name = len > 3 ? string_words(&w[pos + 3], len - 3) : 0;
            if (!name) return false;
            for (size_t k = 3 + name; k < len; k++) {
                if (!(split = split_of(m, w[pos + k]))) continue;
                split->listed = true;
                if (w[pos + 1] != FRAGMENT) split->rejected = true;
            }
            break;
        }
        case OP_DECORATE:
            if (len < 3 || !(split = split_of(m, w[pos + 1]))) break;
            if (w[pos + 2] == LOCATION && len >= 4) {
                split->location = w[pos + 3];
                split->located = true;
            } else if (w[pos + 2] == BUILT_IN) {
                split->rejected = true;
            }
            break;
        case OP_DECORATE_ID:
            if (len >= 2 && (split = split_of(m, w[pos + 1]))) split->rejected = true;
            break;
        case OP_GROUP_DECORATE:
            for (size_t k = 2; k < len; k++) {
                if ((split = split_of(m, w[pos + k]))) split->rejected = true;
            }
            break;
        case OP_EXT_INST:
            for (size_t k = 5; k < len; k++) {
                if ((split = split_of(m, w[pos + k]))) split->rejected = true;
            }
            break;
        case OP_VARIABLE:
            if (len >= 5 && (split = split_of(m, w[pos + 4]))) split->rejected = true;
            break;
        }
    }
    uint32_t kept = 0;
    for (uint32_t i = 0; i < m->split_count; i++) {
        Split* split = &m->splits[i];
        if (split->located && split->listed && !split->rejected) m->splits[kept++] = *split;
    }
    m->split_count = kept;
    if (!kept) return false;

    for (size_t pos = 5; pos < m->functions; pos += length(m, pos)) {
        uint32_t len = length(m, pos);
        if (opcode(m, pos) != OP_ENTRY_POINT || w[pos + 1] != FRAGMENT) continue;
        uint32_t splits = 0;
        for (size_t k = 3 + string_words(&w[pos + 3], len - 3); k < len; k++) {
            Split* split = split_of(m, w[pos + k]);
            if (split) splits |= 1u << (split - m->splits);
        }
        if (!splits) continue;
        if (m->entry_count == MAX_ENTRIES) return false;
        m->entries[m->entry_count].function = w[pos + 2];
        m->entries[m->entry_count++].splits = splits;
    }

    for (uint32_t i = 0; i < m->split_count; i++) {
        Split* split = &m->splits[i];
        m->tracked[split->var] = TRACK_ARRAY;
        split->shadow_type = pointer_to(m, PRIVATE, split->array);
        split->output_type = pointer_to(m, OUTPUT, split->element);
        split->first_output = m->next_id;
        m->next_id += split->count;
        if (!split->shadow_type || !split->output_type) return false;
    }
    return true;
}

// `id`, of type `type`, points into a split array: it becomes a Private pointer.
static bool track_pointer(Module* m, uint32_t type, uint32_t id) {
    size_t pointer = def_of(m, type, OP_TYPE_POINTER);
    if (!pointer || m->w[pointer + 2] != OUTPUT || id >= m->bound) return false;
    m->tracked[id] = TRACK_POINTER;
    return pointer_to(m, PRIVATE, m->w[pointer + 3]) != 0;
}

// Every use of the arrays in functions is one the layer can keep as it is,
// with Private pointers.
static bool find_uses(Module* m) {
    const uint32_t* w = m->w;
    for (size_t pos = m->functions; pos < m->n; pos += length(m, pos)) {
        uint32_t len = length(m, pos);
        switch (opcode(m, pos)) {
        case OP_LOAD:
        case OP_COPY_MEMORY:
        case OP_COPY_MEMORY_SIZED:
        case OP_EXT_INST:
            // Loads and copies work the same through Private pointers.
            break;
        case OP_LINE:
        case OP_VECTOR_SHUFFLE:
        case OP_COMPOSITE_EXTRACT:
        case OP_COMPOSITE_INSERT:
        case OP_LOOP_MERGE:
        case OP_SELECTION_MERGE:
        case OP_SWITCH:
            // No pointers, and literals that may look like ids.
            break;
        case OP_STORE:
            if (len < 3 || tracked(m, w[pos + 2])) return false; // the pointer itself stored
            break;
        case OP_ACCESS_CHAIN:
        case OP_IN_BOUNDS_ACCESS_CHAIN:
        case OP_COPY_OBJECT:
            if (len < 4) return false;
            for (size_t k = 4; k < len; k++) {
                if (tracked(m, w[pos + k])) return false;
            }
            if (tracked(m, w[pos + 3]) && !track_pointer(m, w[pos + 1], w[pos + 2])) return false;
            break;
        default:
            for (size_t k = 1; k < len; k++) {
                if (tracked(m, w[pos + k])) return false;
            }
        }
    }
    return true;
}

// MARK: Writing the new module

static void put(Module* m, uint32_t word) {
    if (m->out_failed) return;
    if (m->out_count == m->out_capacity) {
        size_t capacity = m->out_capacity * 2;
        uint32_t* grown = realloc(m->out, capacity * sizeof *grown);
        if (!grown) {
            m->out_failed = true;
            return;
        }
        m->out = grown;
        m->out_capacity = capacity;
    }
    m->out[m->out_count++] = word;
}

static void copy(Module* m, size_t pos) {
    for (uint32_t k = 0; k < length(m, pos); k++) put(m, m->w[pos + k]);
}

static uint32_t entry_splits(const Module* m, uint32_t function) {
    uint32_t splits = 0;
    for (uint32_t i = 0; i < m->entry_count; i++) {
        if (m->entries[i].function == function) splits |= m->entries[i].splits;
    }
    return splits;
}

// The entry point lists each element's output; the array itself only from
// SPIR-V 1.4 on, where the interface names every global variable it uses.
static void put_entry_point(Module* m, size_t pos) {
    uint32_t len = length(m, pos);
    size_t start = m->out_count;
    size_t interface = 3 + string_words(&m->w[pos + 3], len - 3);
    for (size_t k = 0; k < interface; k++) put(m, m->w[pos + k]);
    for (size_t k = interface; k < len; k++) {
        const Split* split = split_of(m, m->w[pos + k]);
        if (!split || m->version >= VERSION_1_4) put(m, m->w[pos + k]);
        for (uint32_t i = 0; split && i < split->count; i++) put(m, split->first_output + i);
    }
    size_t words = m->out_count - start;
    if (m->out_failed || words > 0xffff) {
        m->out_failed = true;
        return;
    }
    m->out[start] = (uint32_t)words << 16 | OP_ENTRY_POINT;
}

// Element i at the array's location + i, with the array's other decorations.
static void put_output_decorations(Module* m, const Split* split) {
    for (uint32_t i = 0; i < split->count; i++) {
        put(m, 4u << 16 | OP_DECORATE);
        put(m, split->first_output + i);
        put(m, LOCATION);
        put(m, split->location + i);
        for (size_t pos = 5; pos < m->functions; pos += length(m, pos)) {
            uint32_t len = length(m, pos);
            if (opcode(m, pos) != OP_DECORATE || len < 3 || m->w[pos + 1] != split->var || m->w[pos + 2] == LOCATION) continue;
            put(m, m->w[pos]);
            put(m, split->first_output + i);
            for (uint32_t k = 2; k < len; k++) put(m, m->w[pos + k]);
        }
    }
}

// After every type: the pointer types the layer adds, the arrays as Private
// variables, and the element outputs.
static void put_variables(Module* m) {
    for (size_t i = m->module_pointers; i < m->pointer_count; i++) {
        put(m, 4u << 16 | OP_TYPE_POINTER);
        put(m, m->pointers[i].id);
        put(m, m->pointers[i].storage);
        put(m, m->pointers[i].pointee);
    }
    for (uint32_t s = 0; s < m->split_count; s++) {
        const Split* split = &m->splits[s];
        size_t pos = split->declaration;
        put(m, m->w[pos]);
        put(m, split->shadow_type);
        put(m, split->var);
        put(m, PRIVATE);
        for (uint32_t k = 4; k < length(m, pos); k++) put(m, m->w[pos + k]); // the initializer
        for (uint32_t i = 0; i < split->count; i++) {
            put(m, 4u << 16 | OP_VARIABLE);
            put(m, split->output_type);
            put(m, split->first_output + i);
            put(m, OUTPUT);
        }
    }
}

static void put_copies(Module* m, uint32_t splits) {
    for (uint32_t s = 0; s < m->split_count; s++) {
        if (!(splits & 1u << s)) continue;
        const Split* split = &m->splits[s];
        uint32_t array = m->next_id++;
        put(m, 4u << 16 | OP_LOAD);
        put(m, split->array);
        put(m, array);
        put(m, split->var);
        for (uint32_t i = 0; i < split->count; i++) {
            uint32_t element = m->next_id++;
            put(m, 5u << 16 | OP_COMPOSITE_EXTRACT);
            put(m, split->element);
            put(m, element);
            put(m, array);
            put(m, i);
            put(m, 3u << 16 | OP_STORE);
            put(m, split->first_output + i);
            put(m, element);
        }
    }
}

static uint32_t* write_module(Module* m, size_t* new_words) {
    const uint32_t* w = m->w;
    m->out_capacity = m->n + m->n / 4 + 256;
    if (!(m->out = malloc(m->out_capacity * sizeof *m->out))) return NULL;
    for (size_t k = 0; k < 5; k++) put(m, w[k]);
    uint32_t splits = 0; // those the current function's entry points list
    for (size_t pos = 5; pos < m->n; pos += length(m, pos)) {
        uint32_t op = opcode(m, pos), len = length(m, pos);
        if (pos == m->functions) put_variables(m);
        if (pos < m->functions) {
            Split* split;
            if (op == OP_ENTRY_POINT) {
                put_entry_point(m, pos);
                continue;
            }
            if (op == OP_DECORATE && len >= 3 && (split = split_of(m, w[pos + 1]))) {
                // The array keeps RelaxedPrecision; the location and the rest go to its outputs.
                if (w[pos + 2] == LOCATION && !split->decorated) {
                    put_output_decorations(m, split);
                    split->decorated = true;
                } else if (w[pos + 2] == RELAXED_PRECISION) {
                    copy(m, pos);
                }
                continue;
            }
            if (op == OP_VARIABLE && len >= 3 && split_of(m, w[pos + 2])) continue; // in put_variables, after the types it needs
            copy(m, pos);
            continue;
        }
        if (op == OP_FUNCTION) splits = len >= 3 ? entry_splits(m, w[pos + 2]) : 0;
        if (op == OP_RETURN && splits) put_copies(m, splits);
        if ((op == OP_ACCESS_CHAIN || op == OP_IN_BOUNDS_ACCESS_CHAIN || op == OP_COPY_OBJECT)
            && w[pos + 2] < m->bound && m->tracked[w[pos + 2]] == TRACK_POINTER) {
            size_t type = def_of(m, w[pos + 1], OP_TYPE_POINTER);
            put(m, w[pos]);
            put(m, find_pointer(m, PRIVATE, w[type + 3]));
            for (uint32_t k = 2; k < len; k++) put(m, w[pos + k]);
            continue;
        }
        copy(m, pos);
    }
    if (m->out_failed || m->next_id > MAX_BOUND) return NULL;
    m->out[3] = m->next_id;
    *new_words = m->out_count;
    return m->out;
}

uint32_t* avo_split_output_arrays(const uint32_t* code, size_t words, size_t* new_words) {
    if (!code || !new_words || words < 5 || words > UINT32_MAX || code[0] != MAGIC) return NULL;
    Module m = {.w = code, .n = words, .functions = words, .version = code[1], .bound = code[3], .next_id = code[3]};
    if (m.bound < 2 || m.bound > MAX_BOUND) return NULL;
    // Whole instructions, a fragment entry point and a function.
    bool fragment = false;
    for (size_t pos = 5; pos < words; pos += length(&m, pos)) {
        uint32_t len = length(&m, pos);
        if (len == 0 || len > words - pos) return NULL;
        if (opcode(&m, pos) == OP_ENTRY_POINT && len >= 3 && code[pos + 1] == FRAGMENT) fragment = true;
        if (opcode(&m, pos) == OP_FUNCTION && m.functions == words) m.functions = pos;
    }
    if (!fragment || m.functions == words) return NULL;

    uint32_t* result = NULL;
    m.def = calloc(m.bound, sizeof *m.def);
    m.tracked = calloc(m.bound, 1);
    if (m.def && m.tracked && find_splits(&m) && find_uses(&m)) result = write_module(&m, new_words);
    if (!result) free(m.out);
    free(m.def);
    free(m.tracked);
    free(m.pointers);
    return result;
}
