module ModelingToolkitParameters
using ModelingToolkit
using SymbolicIndexingInterface
using Symbolics
using SciMLBase
using InteractiveUtils: clipboard
using TOML
using AbstractTrees
using Logging

export MTKParams, get_parent, get_defs, pmap, cache, update!, @mtkparams, save_parameters, load_parameters

"""
    MTKParams(Model::Function; kwargs...)
    MTKParams(sys::System;     kwargs...)

A mutable, hierarchical parameter container for a ModelingToolkit `System`. Each
field mirrors a parameter or sub-system of the underlying model and can be read or
mutated with normal `getproperty`/`setproperty!` syntax (e.g. `pars.resistor.R = 2`).
Bounds attached to parameters via `@parameters X, [bounds=(lo, hi)]` are enforced
on assignment.

The system must NOT be structurally simplified — construct it with `@named`
(`@mtkcompile`/`@mtkbuild` will throw). Initial values come from
`ModelingToolkit.initial_conditions(sys)`. Any keyword arguments are applied as
parameter overrides after construction.

Use [`pmap`](@ref) (or `model => pars`) to convert a `MTKParams` into the
parameter map expected by `ODEProblem`/`SciMLBase.remake`, and [`cache`](@ref) +
[`update!`](@ref) for fast in-place updates.

# Examples
```julia
pars = MTKParams(RCModel)
pars.resistor.R = 2.0

pars = MTKParams(ConstantVoltage; V = 20)
```
"""
struct MTKParams
    parent::System
    defs::Dict
    # Parameters of *this* system that an enclosing parent binds via a namespaced
    # entry in the parent's binding registry (Dyad's code generator does this),
    # mapped to the expression they are bound to. Captured at descent time by
    # `getproperty`, since a child `System` has no back-reference to its parent.
    # Empty for the top-level system and for hand-written child-local bindings.
    bound::Dict{Symbol, Any}
end

# Backward-compatible constructor: no parent-imposed bindings on this system.
# `defs` is left untyped so any AbstractDict (e.g. `initial_conditions`'s
# AtomicArrayDict) is converted by the inner constructor, as before.
MTKParams(parent::System, defs) = MTKParams(parent, defs, Dict{Symbol, Any}())

function MTKParams(Model::Function; kwargs...)
  @named sys = Model()
  return MTKParams(sys; kwargs...)
end

function MTKParams(sys::System; kwargs...)
  #NOTE: sys must be not structuraly simplified because we need access to the sub-systems
  @assert !ModelingToolkit.iscomplete(sys) "`MTKParams` cannot accept a structualy simplified system, please use @named only"
  m = MTKParams(ModelingToolkit.toggle_namespacing(sys, false), ModelingToolkit.initial_conditions(sys))
  
  for (key, value) in kwargs
    setproperty!(m, key, value)
  end
  
  return m
end

"""
    get_parent(p::MTKParams) -> System

Return the underlying (un-simplified) `System` that backs `p`. Use this instead of
`p.parent`, since `getproperty` on a `MTKParams` looks up parameters by name.
"""
get_parent(obj::MTKParams) = getfield(obj, :parent)

"""
    get_defs(p::MTKParams) -> Dict

Return the internal `symbolic_parameter => value` dictionary holding the current
overrides for `p`. Mutating the returned dict mutates `p`.
"""
get_defs(obj::MTKParams) = getfield(obj, :defs)

"""
    get_bound(p::MTKParams) -> Dict{Symbol, Any}

Return the `param_name => bound_expression` map of parameters of `p`'s system that
are bound by an *enclosing* parent (see [`parent_bindings`](@ref)). These cannot be
set independently and are hidden from [`propertynames`](@ref).
"""
get_bound(obj::MTKParams) = getfield(obj, :bound)

function Base.getproperty(x::MTKParams, var::Symbol)
    parent = get_parent(x)
    defs = get_defs(x)

    sym = getproperty(parent, var)

    if typeof(sym) <: System
      return MTKParams(sym, defs, parent_bindings(parent, var))
    else
      if !haskey(defs, sym)
        if ModelingToolkit.hasdefault(sym)
          return ModelingToolkit.getdefault(sym)
        else
          return nothing
        end
      else
        return Symbolics.value(defs[sym])
      end
    end
end

function Base.setproperty!(x::MTKParams, var::Symbol, val)
    # A `nothing` value means "leave this parameter at its existing/default value".
    # This lets a partial override like `MTKParams(ConstantVoltage; V=30)` be merged
    # into a parent without clobbering sibling defaults (e.g. `special`'s E1/E2) with
    # `nothing` when the subsystem-merge loop below reads unset properties.
    val === nothing && return nothing

    parent = get_parent(x)
    defs = get_defs(x)

    sym = getproperty(parent, var)

    if ModelingToolkit.isparameter(sym)
      # A parameter can be bound either in `parent`'s own registry (hand-written
      # `Child(; p = expr)`) or by an enclosing parent under a namespaced key
      # (Dyad codegen), captured in `get_bound(x)`. Both are un-settable.
      if var in bound_parameter_names(parent)
        bound_error(sym, binding_source(parent, var))
      elseif haskey(get_bound(x), var)
        bound_error(sym, get_bound(x)[var])
      end

      if ModelingToolkit.hasbounds(sym)
        bounds = ModelingToolkit.getbounds(sym)
        
        if val < bounds[1]
          error("exceeded minimum bound $(bounds[1])")
        end

        if val > bounds[2]
          error("exceeded maxiumu bound $(bounds[2])")
        end
      end

      defs[sym] = val
    end

    if (sym isa System) & (val isa MTKParams)

      child = getproperty(x, var)
      for nm in propertynames(child)
        setproperty!(child, nm, getproperty(val, nm))
      end

    end

    return nothing
end

Base.ismutable(x::MTKParams) = true

"""
    bound_parameter_names(sys::System) -> Set{Symbol}

Return the names of the *bound* parameters local to `sys`. A parameter is bound
when its value is fixed to an expression of other parameters via a binding, e.g.
created by passing a parameter into a sub-component:

```julia
@parameters my_p
@named inner = Foo(; p2 = my_p)   # inner.p2 is bound to my_p
```

Bound parameters are substituted away when the system is compiled and therefore
cannot be set independently — only the binding source (`my_p` here) can be
changed. `MTKParams` hides them from [`propertynames`](@ref) so they don't appear
in the parameter object, the tree display, `pmap`, or `cache`. A plain numeric
override (`p2 = 5.0`) is *not* a binding and stays tunable.

This mirrors `ModelingToolkit.bound_parameters`, but reads the binding registry
directly via `ModelingToolkit.bindings` so it works on the *uncompiled*
hierarchical system that `MTKParams` requires (`bound_parameters` needs a
completed system). Matching is by name: the symbol returned by `getproperty` on a
sub-system is not identical (`isequal`) to the one in the binding registry, so a
dict lookup by identity is unreliable.
"""
# A binding value of `missing` marks an *unresolved* binding: the parameter has no
# fixed expression yet and stays tunable (matching `bound_parameters`). MTK records a
# `p = missing, [guess=...]` default as a symbolic-`missing` constant, so `ismissing`
# alone misses it — `Symbolics.value` unwraps the symbolic to the underlying `missing`
# first (and is a no-op on plain `missing` and on real binding expressions).
is_unresolved_binding(v) = ismissing(Symbolics.value(v))

function bound_parameter_names(sys::System)
  ModelingToolkit.has_bindings(sys) || return Set{Symbol}()
  binds = ModelingToolkit.get_bindings(sys)
  names = Set{Symbol}()
  for k in keys(binds)
    is_unresolved_binding(binds[k]) && continue
    push!(names, Symbol(ModelingToolkit.getname(k)))
  end
  return names
end

"""
    binding_source(sys::System, var::Symbol)

Return the expression that the bound parameter `var` (local to `sys`) is bound to,
for use in error messages. Looks the binding up by name (see
[`bound_parameter_names`](@ref) for why identity lookup is unreliable).
"""
function binding_source(sys::System, var::Symbol)
  ModelingToolkit.has_bindings(sys) || return nothing
  binds = ModelingToolkit.get_bindings(sys)
  for k in keys(binds)
    Symbol(ModelingToolkit.getname(k)) == var && return binds[k]
  end
  return nothing
end

bound_error(sym, source) =
  error("`$(ModelingToolkit.getname(sym))` is bound to `$(source)` and cannot be set independently; set `$(source)` instead.")

"""
    parent_bindings(parent::System, subname::Symbol) -> Dict{Symbol, Any}

Return the direct parameters of sub-system `subname` that are bound by an entry in
`parent`'s binding registry, mapped to the expression they are bound to.

Dyad's code generator records a child parameter binding on the *parent* under the
namespaced key `subname₊param` (via `bindings[child.param] = expr`) rather than on
the child under `param`. Such a child, examined in isolation, looks unbound because
[`bound_parameter_names`](@ref) only reads its own registry. This recovers those
names from the enclosing `parent`, so `MTKParams` can hide/protect them the same way
it does hand-written child-local bindings.
"""
function parent_bindings(parent::System, subname::Symbol)
  res = Dict{Symbol, Any}()
  ModelingToolkit.has_bindings(parent) || return res
  prefix = string(subname) * ModelingToolkit.NAMESPACE_SEPARATOR
  for (k, v) in ModelingToolkit.get_bindings(parent)
    is_unresolved_binding(v) && continue  # unresolved bindings stay tunable
    name = string(ModelingToolkit.getname(k))
    startswith(name, prefix) || continue
    local_name = chopprefix(name, prefix)
    # only direct parameters of the sub; deeper names belong to its descendants
    occursin(ModelingToolkit.NAMESPACE_SEPARATOR, local_name) && continue
    res[Symbol(local_name)] = v
  end
  return res
end

"""
    is_free_param(sys::System, par) -> Bool

Return `true` for parameters of `sys` that `MTKParams` should expose: real
parameters that are neither `Initial(...)` bookkeeping parameters nor bound to
another expression (see [`bound_parameter_names`](@ref)).
"""
is_free_param(sys::System, par, bnames = bound_parameter_names(sys)) =
  !ModelingToolkit.isinitial(par) && !(Symbol(ModelingToolkit.getname(par)) in bnames)

"""
    has_nested_parameter(sys::System, extra_bound = Set{Symbol}()) -> Bool

Return `true` if `sys` (or any descendant) exposes a free parameter. `extra_bound`
names parameters of `sys` that an enclosing parent binds via a namespaced entry
(see [`parent_bindings`](@ref)) and are therefore *not* free. When recursing, each
sub-system is checked against the names `sys` binds for it, so parent-side (Dyad)
bindings are honoured at every level.

    has_nested_parameter(parent::System, subname::Symbol) -> Bool

Convenience method: check sub-system `subname` of `parent`, automatically supplying
the parameters `parent` binds for it. Use this instead of
`has_nested_parameter(parent.subname)` — a child fetched with `getproperty` carries
no reference back to `parent`, so the parent's bindings would otherwise be invisible.
"""
function has_nested_parameter(sys::System, extra_bound::Set{Symbol} = Set{Symbol}())

  bnames = union(bound_parameter_names(sys), extra_bound)
  if any(par -> is_free_param(sys, par, bnames), ModelingToolkit.get_ps(sys))
    return true
  end

  ss = ModelingToolkit.get_systems(sys)

  if !isempty(ss)
    return any(sub -> has_nested_parameter(sub, sub_bound_names(sys, sub)), ss)
  else
    return false
  end

end

has_nested_parameter(parent::System, subname::Symbol) =
  has_nested_parameter(getproperty(parent, subname), sub_bound_names(parent, subname))

# Names of `sub`'s parameters that `parent` binds via a namespaced entry.
sub_bound_names(parent::System, sub::System) =
  sub_bound_names(parent, Symbol(ModelingToolkit.getname(sub)))
sub_bound_names(parent::System, subname::Symbol) =
  Set{Symbol}(keys(parent_bindings(parent, subname)))


function Base.propertynames(x::MTKParams; private = false)
  sys = get_parent(x)
  # defs = get_defs(x)

  names = Symbol[]

  # `bound_parameter_names(sys)` covers child-local bindings; `get_bound(x)` adds
  # parameters bound by an enclosing parent (Dyad codegen), captured at descent.
  bnames = union(bound_parameter_names(sys), keys(get_bound(x)))
  for par in ModelingToolkit.get_ps(sys)
    # scope = ModelingToolkit.getmetadata(par, ModelingToolkit.SymScope, ModelingToolkit.LocalScope())
    # scope isa ModelingToolkit.GlobalScope && continue

    # is_free_param avoids Initial(x) "parameters" and parameters bound to
    # another expression (e.g. `@named inner = Foo(; p2 = my_p)`), which cannot
    # be set independently once the system is compiled.
    if is_free_param(sys, par, bnames)
      push!(names, Symbol(ModelingToolkit.getname(par)))
    end
  end

  for sub in ModelingToolkit.get_systems(sys)
    if has_nested_parameter(sub, sub_bound_names(sys, sub))
      push!(names, Symbol(ModelingToolkit.getname(sub)))
    end
  end

  return names
end



function Base.isequal(x::MTKParams, y::MTKParams)
  
  names1 = propertynames(x)
  names2 = propertynames(y)
  if length(names1) != length(names2)
    return false
  end
  
  for name in names1
    if !hasproperty(y, name)
      return false
    end

    if !isequal(getproperty(x, name), getproperty(y, name))
      return false
    end
  end

  return true
end


"""
    ParamsNode(name, value)

Internal wrapper used by the `AbstractTrees` integration so each field carries the
name it had on its parent, enabling pretty tree printouts of `MTKParams` instances.
"""
struct ParamsNode
    name::Symbol
    value::Any
end

AbstractTrees.children(x::MTKParams) =
    [ParamsNode(n, getproperty(x, n)) for n in propertynames(x)]

AbstractTrees.children(n::ParamsNode) =
    n.value isa MTKParams ? AbstractTrees.children(n.value) : ()

function AbstractTrees.printnode(io::IO, x::MTKParams) 
  parent =  get_parent(x)
  component_type = ModelingToolkit.get_component_type(parent)
  print(io, component_type.name)
end

function AbstractTrees.printnode(io::IO, n::ParamsNode)
    if n.value isa MTKParams
        print(io, n.name)
    else
        print(io, n.name, ": ", n.value)
    end
end

Base.show(io::IO, ::MIME"text/plain", x::MTKParams) =
    AbstractTrees.print_tree(io, x)

PMapDict = Dict{SymbolicUtils.BasicSymbolicImpl.var"typeof(BasicSymbolicImpl)"{SymReal}, SymbolicUtils.BasicSymbolicImpl.var"typeof(BasicSymbolicImpl)"{SymReal}}

"""
    pmap(model::System, pars::MTKParams) -> Dict

Build a `Dict{symbolic_parameter, value}` keyed by the symbolic parameters of
`model`. This is the form accepted by [`update!`](@ref) and the cache-aware
`SciMLBase.remake(prob, setters, param_dict)` method.

For the flat `Vector{Pair}` form expected by `ODEProblem` and the standard
`SciMLBase.remake(prob; p = ...)`, write `model => pars` instead.
"""
pmap(model::System, pars::MTKParams) = PMapDict(model => pars)

"""
    Pair(model::System, pars::MTKParams) -> Vector{Pair}

Flatten `pars` against `model` into a `Vector{Pair}` of `symbolic_parameter => value`
entries (recursively walking sub-systems). This is the form accepted by
`ODEProblem` and `SciMLBase.remake(prob; p = ...)`. Equivalent to writing
`model => pars`.

Fields of `pars` that don't have a matching property on `model` produce a warning
and are skipped.
"""
function Base.Pair(model::System, pars::MTKParams)

  #TODO: confirm that model and pars are properly paired


  prs = Pair[]
  for nm in propertynames(pars)
    if hasproperty(model, nm)
      sym = getproperty(model,nm)
      val = getproperty(pars,nm)
      x = ModelingToolkit.unwrap(sym) => val
      if x isa Vector
        append!(prs, x)
      else
        # if !ismissing(val) & !isnothing(val)
        push!(prs, x)
        # end
      end
    else
      @warn "$(ModelingToolkit.get_name(model)) does not contain $nm"
    end
  end

  return prs
end



# support for saving ----------------------------
function Base.Dict(x::MTKParams)

  children = Pair[] 

  for nm in propertynames(x)

      prop = getproperty(x, nm)
      if typeof(prop) <: MTKParams
        val = Dict(prop)
      else
        val = prop
      end
      push!(children, nm => val)
    
  end

  return Dict(children)
end


function Base.setproperty!(x::MTKParams, dict::Dict)
    for (key,value) in dict
        skey = Symbol(key)
        if value isa Dict
          setproperty!(getproperty(x, skey), value)
        elseif value isa String
          setproperty!(x, skey, eval(Meta.parse(value)))
        else
          setproperty!(x, skey, value)
        end
    end
end

#TODO: doesn't work, why?
# function Base.setproperty!(sys::System, x::T) where T <: Params
#   defs = ModelingToolkit.defaults(sys)
#   setproperty!(defs, x, sys)
# end


function Base.setproperty!(dict::Dict, x::MTKParams, sys::System)
  for nm in propertynames(x)
    prop = getproperty(x, nm)
    if prop isa MTKParams
      setproperty!(dict, prop, getproperty(sys, nm))
    else
      dict[getproperty(sys, nm)] = prop
    end
  end
end


function Base.copy(x::MTKParams)
    return MTKParams(get_parent(x), copy(get_defs(x)), copy(get_bound(x)))
end

# fallback value conversion
convert_value(x) = x
convert_value(x::Missing) = "missing"

"""
    save_parameters(x::MTKParams, filepath::String)

Write `x` to `filepath` as a hierarchical TOML file. `missing` values are stored
as the string `"missing"` so they round-trip through [`load_parameters`](@ref).
"""
function save_parameters(x::MTKParams, filepath::String)

  open(filepath, "w") do io
    TOML.print(convert_value, io, Dict(x))
  end

end

"""
    parameters_to_string(x::MTKParams) -> String

Return the TOML representation of `x` as a `String`. Same format as
[`save_parameters`](@ref) writes, but without touching the filesystem.
"""
function parameters_to_string(x::MTKParams)
  io = IOBuffer()
  TOML.print(convert_value, io, Dict(x))
  return String(take!(io))
end

"""
    load_parameters(filepath::String, model::Function) -> MTKParams

Construct a fresh `MTKParams(model)` and apply the values stored in the TOML file
at `filepath` (typically written by [`save_parameters`](@ref)).
"""
function load_parameters(filepath::String, model::Function)

  x = MTKParams(model)
  setproperty!(x, TOML.parsefile(filepath))

  return x
end

"""
    load_parameters(filepath::String, sys::System) -> MTKParams

Construct a fresh `MTKParams(sys)` and apply the values stored in the TOML file
at `filepath` (typically written by [`save_parameters`](@ref)).
"""
function load_parameters(filepath::String, sys::System)

  x = MTKParams(sys)
  setproperty!(x, TOML.parsefile(filepath))

  return x
end

"""
    load_parameters(filepath::String, x::MTKParams) -> MTKParams

Apply the values stored in the TOML file at `filepath` 
(typically written by [`save_parameters`](@ref)) to the `x::MTKParams` 
parameter object.
"""
function load_parameters(filepath::String, x::MTKParams)

  setproperty!(x, TOML.parsefile(filepath))

  return x
end

"""
    string_to_parameters(contents::String, x::MTKParams) -> MTKParams

Apply parameter values parsed from the TOML string `contents` to the existing
`MTKParams` instance `x`, mutating it in place. Returns `x`.
"""
function string_to_parameters(contents::String, x::MTKParams)

  setproperty!(x, TOML.parse(contents))

  return x
end


"""
    cache(model::System, x::MTKParams; parent = model) -> Vector{ParameterHookWrapper}

Pre-build a vector of `SymbolicIndexingInterface` setter functions, one per
parameter field reachable from `x` (recursing into sub-systems). Pass the result,
together with a parameter map from [`pmap`](@ref), to [`update!`](@ref) or
`SciMLBase.remake` to mutate an `ODEProblem` without rebuilding the setters on
each call.

`parent` is the top-level system used when constructing each `setp` setter; it
only differs from `model` when `cache` recurses into a sub-system.
"""
function cache(model::System, x::MTKParams; parent=model)

  prs = SymbolicIndexingInterface.ParameterHookWrapper[]
  for nm in propertynames(x)
    if hasproperty(model, nm)
      p = getproperty(model,nm)
      if p isa System 
        ps = cache(p, getproperty(x, nm); parent)
        append!(prs, ps)
      else
        setter = setp(parent, p)
        push!(prs, setter)
      end
    end
  end

  return prs
end


"""
    update!(prob::ODEProblem,
            setters::Vector{ParameterHookWrapper},
            param_dict::Dict) -> prob

Mutate `prob` in place by applying every setter in `setters` whose target
parameter appears in `param_dict`. `setters` is produced by [`cache`](@ref) and
`param_dict` by [`pmap`](@ref). Entries with `missing` values are skipped (the
underlying setters do not accept `missing`). Returns `prob`.
"""
function update!(prob::ODEProblem, setters::Vector{SymbolicIndexingInterface.ParameterHookWrapper}, param_dict::PMapDict)

  # Apply each setter by matching its parameter to the param_dict
  for setter in setters
    # Get the parameter that this setter operates on
    param = setter.original_index

    # If this parameter is in our update map, apply it
    if haskey(param_dict, param)
      val = Symbolics.value(param_dict[param])
      if !ismissing(val) #setters don't support missing
        setter(prob, val)
      end
    end
  end

  return prob
end


"""
    SciMLBase.remake(prob::ODEProblem,
                     setters::Vector{ParameterHookWrapper},
                     param_dict::Dict) -> ODEProblem

Non-mutating counterpart to [`update!`](@ref): copies `prob.p` first so the
original `prob` is left untouched, then applies the matching setters from
`param_dict`. Use this when you need a new problem but want to keep the original
intact.
"""
function SciMLBase.remake(prob::ODEProblem, setters::Vector{SymbolicIndexingInterface.ParameterHookWrapper}, param_dict::PMapDict)
    prob′ = SciMLBase.remake(prob; p = copy(prob.p)) #NOTE: if p is not set to a copy then p maintains the original reference
    update!(prob′, setters, param_dict)
    # return SciMLBase.remake(prob′) # Note: using remake a 2nd time could be implemented to provide initialization for solvable parameters, see example below...
    return prob′
end


"""
    @mtkparams name = Model(; sub = ChildComponent(p = 1), kw = value, ...)
    @mtkparams const name = Model(; ...)
    @mtkparams Model(; ...)                                   # bare-call form

Convenience macro that rewrites `Model(...)` into `MTKParams(Model; ...)`,
recursively transforming nested component constructor calls into nested
`MTKParams` calls. Wrapping an assignment lets the catalog name appear in front
of the macro so the declaration reads top-to-bottom; `const` is also supported.
The bare-call form (`name = @mtkparams Model(...)`) still works.

# Example
```julia
@mtkparams seat_pars = MassSpringDamper(
    body   = Mass(m = 100),
    spring = Spring(k = 1000),
    damper = Damper(d = 1),
)
```
expands (roughly) to
```julia
seat_pars = MTKParams(MassSpringDamper;
    body   = MTKParams(Mass;   m = 100),
    spring = MTKParams(Spring; k = 1000),
    damper = MTKParams(Damper; d = 1),
)
```
"""
macro mtkparams(expr)
    return esc(transform_params(expr))
end

function transform_params(expr)
    # Pass `const` declarations through, transforming the inner assignment
    if expr isa Expr && expr.head === :const
        return Expr(:const, transform_params(expr.args[1]))
    end

    # Pass assignments through, transforming only the right-hand side
    if expr isa Expr && expr.head === :(=)
        lhs = expr.args[1]
        rhs = transform_params(expr.args[2])
        return Expr(:(=), lhs, rhs)
    end

    # Base case: if it's not a function call (like a number or symbol), return it as is
    if !(expr isa Expr && expr.head === :call)
        return expr
    end

    # Extract the type (e.g., MassSpringDamper) and the arguments
    model_type = expr.args[1]
    args = expr.args[2:end]

    # Process each argument recursively
    processed_args = map(args) do arg
        if arg isa Expr && arg.head === :kw
            # Handle keyword arguments: key = value
            key = arg.args[1]
            value = transform_params(arg.args[2])
            return Expr(:kw, key, value)
        else
            # Handle positional arguments
            return transform_params(arg)
        end
    end

    # Reconstruct as MTKParams(ModelType; kwargs...)
    return :(MTKParams($model_type; $(processed_args...)))
end

end # module ModelingToolkitParameters
