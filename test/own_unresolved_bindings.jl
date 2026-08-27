# Regression test: a component that declares one of its OWN parameters unresolved
# (`missing`) directly in its own local binding registry, rather than relying on an
# enclosing system to re-bind it under a namespaced key. Dyad emits `p = missing,
# [guess=...]` this way whenever the initialization parameter is declared directly
# on the component itself, instead of being lifted/re-bound by whatever embeds it.
# `parent_unresolved_names` alone cannot see this — it only reads the *enclosing*
# system's registry for a namespaced `child.p` entry. See `own_unresolved_names`.

using ModelingToolkit
using ModelingToolkit: t_nounits as t
using ModelingToolkitParameters
using ModelingToolkitParameters: own_unresolved_names, get_unresolved
using Test

# A leaf component whose own registry binds one of its own parameters to `missing`.
@component function OwnUnresolvedLeaf(; name)
    @parameters p q
    bindings = Dict(p => missing)
    guesses = Dict(p => 0.0)
    System(Equation[], t, [], [p, q]; name, bindings, guesses)
end

# A wrapper that never mentions `child.p` in its own registry — the only place the
# `missing` marker exists is on `child`'s own local bindings.
@component function OwnUnresolvedParent(; name)
    @named child = OwnUnresolvedLeaf()
    System(Equation[], t, [], []; name, systems = [child])
end

@named C = OwnUnresolvedLeaf()
@test own_unresolved_names(C) == Set([:p])

# Top-level system: its own unresolved parameter must read back as `missing`, while
# an ordinary unset parameter (`q`) still reads back as `nothing`.
pars_top = MTKParams(OwnUnresolvedLeaf)
@test get_unresolved(pars_top) == Set([:p])
@test ismissing(pars_top.p)
@test pars_top.q === nothing

# Nested: descending into `child` must pick up `child`'s own unresolved binding even
# though `OwnUnresolvedParent` never re-binds `child.p` itself.
pars = MTKParams(OwnUnresolvedParent)
@test get_unresolved(pars.child) == Set([:p])
@test ismissing(pars.child.p)
@test pars.child.q === nothing

# It stays settable, and once set reads back the concrete value.
pars.child.p = 3.0
@test pars.child.p == 3.0
