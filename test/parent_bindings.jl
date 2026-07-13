# Regression test: a child parameter bound on the PARENT under the namespaced key
# `child₊bound` (as Dyad's code generator emits) must be recognised as bound, the
# same as a hand-written child-local binding. See `parent_bindings`.

using ModelingToolkit
using ModelingToolkit: t_nounits as t
using ModelingToolkitParameters
using ModelingToolkitParameters: has_nested_parameter, get_parent, parent_bindings
using Test

# A plain child with its own (unbound) `bound` parameter.
@component function PlainChild(; name)
    @parameters bound = 1
    System(Equation[], t, [], [bound]; name)
end

# Dyad shape: the binding is registered on the PARENT, keyed by the namespaced
# `child.bound`, rather than passed into the child.
@component function DyadParent(; name)
    @parameters bound = 1
    @named child = PlainChild()
    bindings = Dict(child.bound => bound)
    System(Equation[], t, [], [bound]; name, systems = [child], bindings)
end

@named p = DyadParent()

# The binding lives on the parent, not on the child.
@test isempty(ModelingToolkit.get_bindings(p.child))
@test Set(keys(parent_bindings(p, :child))) == Set([:bound])

# Parent-aware check: the child's only parameter is bound, so it has no free
# nested parameter. (The bare `has_nested_parameter(p.child)` cannot know this —
# the child carries no back-reference to its parent.)
@test has_nested_parameter(p, :child) == false

pars = MTKParams(DyadParent)

# `child` is fully bound -> hidden; the parent's own `bound` stays free.
@test :bound in propertynames(pars)
@test :child ∉ propertynames(pars)

# Descending into the (bound) child hides the parameter and blocks writes...
@test :bound ∉ propertynames(pars.child)
@test_throws ErrorException pars.child.bound = 5

# ...while the genuinely free parent parameter remains settable.
pars.bound = 7
@test pars.bound == 7
