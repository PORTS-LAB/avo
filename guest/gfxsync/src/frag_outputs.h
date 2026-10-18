// Splits arrayed fragment shader outputs for MoltenVK (frag_outputs.c says why).
#pragma once

#include <stddef.h>
#include <stdint.h>

// Rewrites each fragment output array (`layout(location = L) out vec4 x[N]`)
// as N outputs at locations L to L+N-1. Returns the new module, which the
// caller frees, and its length in words; NULL when the module has no such
// output or when the layer cannot rewrite it safely (the caller then uses the
// module as it is).
uint32_t* avo_split_output_arrays(const uint32_t* code, size_t words, size_t* new_words);
