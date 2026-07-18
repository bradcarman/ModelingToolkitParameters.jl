# Regression test: a child parameter that the PARENT binds to an *unresolved* value
# (`missing`) — as Dyad emits for `p = missing, [guess=...]` initialization params
# (e.g. `__bindings[spring_damper.s_rel0] = missing`) — must stay tunable/visible
# AND read back as `missing`, not `nothing`. See `parent_unresolved_names`.

using ModelingToolkit
using ModelingToolkit: t_nounits as t
using ModelingToolkitParameters
using ModelingToolkitParameters: parent_bindings, parent_unresolved_names, get_unresolved
using Test

# A child with a parameter that has NO local default (its value is meant to be
# supplied/solved from the outside), mirroring a Dyad init parameter whose child
# initial condition has been deleted.
@component function UnresolvedChild(; name)
    @parameters p
    System(Equation[], t, [], [p]; name)
end

# Dyad shape: the parent binds the child parameter to `missing` (unresolved) and
# provides a guess, registered on the PARENT under the namespaced key `child.p`.
@component function UnresolvedParent(; name)
    @named child = UnresolvedChild()
    bindings = Dict(child.p => missing)
    guesses = Dict(child.p => 0.0)
    System(Equation[], t, [], []; name, systems = [child], bindings, guesses)
end

@named P = UnresolvedParent()

# The unresolved binding lives on the parent and is deliberately excluded from the
# resolved-binding set (so the parameter stays tunable), but is captured separately.
@test isempty(parent_bindings(P, :child))
@test parent_unresolved_names(P, :child) == Set([:p])

pars = MTKParams(UnresolvedParent)

# An unresolved binding stays tunable: the child is exposed and so is its parameter.
@test :child in propertynames(pars)
@test :p in propertynames(pars.child)

# The captured unresolved set is available on the descended child.
@test get_unresolved(pars.child) == Set([:p])

# The bug: this used to read back as `nothing`. It must be `missing`.
@test ismissing(pars.child.p)
@test pars.child.p !== nothing

# It stays settable, and once set reads back the concrete value.
pars.child.p = 5.0
@test pars.child.p == 5.0

# A fresh object again reports `missing` (nothing leaked into defaults)...
pars2 = MTKParams(UnresolvedParent)
@test ismissing(pars2.child.p)

# ...and `copy` preserves the unresolved-value behaviour (exercises the copied
# `unresolved` field directly on a child object).
@test ismissing(copy(pars2.child).p)
@test copy(pars2).child.p |> ismissing
