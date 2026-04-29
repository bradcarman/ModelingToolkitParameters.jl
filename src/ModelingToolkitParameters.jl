module ModelingToolkitParameters
using ModelingToolkit
using SymbolicIndexingInterface
using Symbolics
using SciMLBase
using InteractiveUtils: clipboard
using JuliaFormatter: format_text
using TOML
using AbstractTrees

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
end

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

function Base.getproperty(x::MTKParams, var::Symbol)
    parent = get_parent(x)
    defs = get_defs(x)

    sym = getproperty(parent, var)

    if typeof(sym) <: System
      return MTKParams(sym, defs)
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
    parent = get_parent(x)
    defs = get_defs(x)

    sym = getproperty(parent, var)

    if ModelingToolkit.isparameter(sym)
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
      for nm in fieldnames(child)
        setproperty!(child, nm, getproperty(val, nm))
      end

    end

    return nothing
end


function has_nested_parameter(sys::System)

  ps = ModelingToolkit.get_ps(sys)
  if !isempty(ps)
    return true
  end

  ss = ModelingToolkit.get_systems(sys)

  if !isempty(ss)
    return any([has_nested_parameter(sub) for sub in ss])
  else
    return false
  end

end



function Base.fieldnames(x::MTKParams)
  sys = get_parent(x)
  # defs = get_defs(x)

  names = Symbol[]

  for par in ModelingToolkit.get_ps(sys)
    # scope = ModelingToolkit.getmetadata(par, ModelingToolkit.SymScope, ModelingToolkit.LocalScope())
    # scope isa ModelingToolkit.GlobalScope && continue

    if !ModelingToolkit.isinitial(par) #avoids Initial(x) "parameters"
      push!(names, Symbol(ModelingToolkit.getname(par)))
    end
  end

  for sub in ModelingToolkit.get_systems(sys)
    if has_nested_parameter(sub)
      push!(names, Symbol(ModelingToolkit.getname(sub)))
    end
  end

  return names
end



function Base.isequal(x::MTKParams, y::MTKParams)
  
  names1 = fieldnames(x)
  names2 = fieldnames(y)
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
    [ParamsNode(n, getproperty(x, n)) for n in fieldnames(x)]

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
  for nm in fieldnames(pars)
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

  for nm in fieldnames(x)

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
  for nm in fieldnames(x)
    prop = getproperty(x, nm)
    if prop isa MTKParams
      setproperty!(dict, prop, getproperty(sys, nm))
    else
      dict[getproperty(sys, nm)] = prop
    end
  end
end


function Base.copy(x::MTKParams)
    parent = get_parent(x)
    defs = get_defs(x)

    return MTKParams(parent, copy(defs))
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
  for nm in fieldnames(x)
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
    @mtkparams Model(; sub = ChildComponent(p = 1), kw = value, ...)

Convenience macro that rewrites `Model(...)` into `MTKParams(Model; ...)`,
recursively transforming nested component constructor calls into nested
`MTKParams` calls. Useful for declaring catalog entries inline.

# Example
```julia
seat_pars = @mtkparams MassSpringDamper(
    body   = Mass(m = 100),
    spring = Spring(k = 1000),
    damper = Damper(d = 1),
)
```
expands (roughly) to
```julia
MTKParams(MassSpringDamper;
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
