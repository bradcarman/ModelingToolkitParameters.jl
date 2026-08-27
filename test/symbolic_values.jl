using ModelingToolkit
using ModelingToolkit: D_nounits as D, t_nounits as t
using ModelingToolkitParameters
using SciMLBase
using Test

# A `pdict` value is not always concrete. Dyad's code generator propagates a parent
# parameter into a sub-component by declaring a same-named parameter on the child and
# recording the *parent's symbolic* as the child's initial condition, so a `pdict` entry
# reads `branch₊leaf₊medium_data => branch₊medium_data`. Chains can be several levels
# deep, and derived defaults (`k => medium_gain(medium_data)`) are expressions of them.
#
# `remake(prob; p = ...)` resolves these itself; the `cache`/`update!` path writes
# straight into the parameter buffer, so it has to resolve them first. Before that was
# fixed, a struct-valued parameter failed with `MethodError: Cannot convert an object of
# type BasicSymbolic{SymReal} to an object of type TestMedium`.

# A non-numeric (struct-valued) parameter, e.g. a fluid property object.
struct TestMedium
    name::String
    k::Float64
end

medium_gain(data::TestMedium) = data.k
# Registered so a default like `k = medium_gain(medium_data)` can be built while
# `medium_data` is still symbolic; it folds once the parameter is substituted.
@register_symbolic medium_gain(data::TestMedium)

@component function Leaf(; name, medium_data = nothing, gain = nothing)
    # capture the caller's values before `@parameters` shadows the names
    _medium_data = medium_data
    _gain = gain

    pars = ModelingToolkit.SymbolicT[]
    append!(pars, @parameters (medium_data::TestMedium))
    append!(pars, @parameters (gain::Real))
    append!(pars, @parameters (k::Real))

    vars = @variables x(t) = 0.0

    initial_conditions = [
        medium_data => _medium_data,
        gain => _gain,
        k => medium_gain(medium_data),   # derived: exercises substitute-then-fold
    ]

    return System([D(x) ~ gain * medium_gain(medium_data) + k], t, vars, pars;
        name, initial_conditions)
end

@component function Branch(; name, medium_data = nothing)
    _medium_data = medium_data

    pars = ModelingToolkit.SymbolicT[]
    append!(pars, @parameters (medium_data::TestMedium))
    append!(pars, @parameters (gain::Real))

    # pass this level's symbolics down, exactly as the Dyad codegen does
    @named leaf = Leaf(; medium_data, gain)

    initial_conditions = [medium_data => _medium_data, gain => 2.0]

    return System(Equation[], t, [], pars; name, systems = [leaf], initial_conditions)
end

@component function MediumModel(; name, medium_data = TestMedium("A", 1.0))
    _medium_data = medium_data

    pars = ModelingToolkit.SymbolicT[]
    append!(pars, @parameters (medium_data::TestMedium))

    @named branch = Branch(; medium_data)

    return System(Equation[], t, [], pars; name, systems = [branch],
        initial_conditions = [medium_data => _medium_data])
end

@mtkcompile msys = MediumModel()
mprob = ODEProblem(msys, [], (0.0, 1.0))

@mtkparams mpars = MediumModel()
msetters = cache(msys, mpars)

medium_B = TestMedium("B", 5.0)
mpars.medium_data = medium_B
mpars.branch.gain = 7.0

slow = remake(mprob; p = pdict(msys, mpars))          # the path that already worked
fast = remake(mprob, msetters, pdict(msys, mpars))    # the cache path under test

# struct-valued parameter propagated parent -> branch -> leaf (two levels of symbolics)
@test fast.ps[msys.branch.medium_data].name == "B"
@test fast.ps[msys.branch.leaf.medium_data].name == "B"

# numeric parameter propagated branch -> leaf
@test fast.ps[msys.branch.leaf.gain] == 7.0

# derived default resolves *and* folds against the newly assigned medium
@test fast.ps[msys.branch.leaf.k] == 5.0

# the cache path must agree with the standard remake path on every one of them
@test fast.ps[msys.branch.medium_data].name == slow.ps[msys.branch.medium_data].name
@test fast.ps[msys.branch.leaf.medium_data].name == slow.ps[msys.branch.leaf.medium_data].name
@test fast.ps[msys.branch.leaf.gain] == slow.ps[msys.branch.leaf.gain]
@test fast.ps[msys.branch.leaf.k] == slow.ps[msys.branch.leaf.k]

# `remake` must not mutate the original problem
@test mprob.ps[msys.branch.leaf.medium_data].name == "A"
@test mprob.ps[msys.branch.leaf.k] == 1.0

# `update!` mutates in place and resolves the same way
update!(mprob, msetters, pdict(msys, mpars))
@test mprob.ps[msys.branch.leaf.medium_data].name == "B"
@test mprob.ps[msys.branch.leaf.k] == 5.0
