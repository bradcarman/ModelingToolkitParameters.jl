module ModelingToolkitParameters
using ModelingToolkit
using SymbolicIndexingInterface
using Symbolics
using SciMLBase
using InteractiveUtils: clipboard
using JuliaFormatter: format_text
using TOML
using AbstractTrees

export ModelParams, get_parent, get_defs, pmap, cache, update!, @model_params, save_parameters, load_parameters

struct ModelParams
    parent::System
    defs::Dict
end

function ModelParams(Model::Function; kwargs...)
  @named sys = Model()
  return ModelParams(sys; kwargs...)
end

function ModelParams(sys::System; kwargs...) 
  #NOTE: sys must be not structuraly simplified because we need access to the sub-systems
  @assert !ModelingToolkit.iscomplete(sys) "`ModelParams` cannot accept a structualy simplified system, please use @named only"
  m = ModelParams(ModelingToolkit.toggle_namespacing(sys, false), ModelingToolkit.initial_conditions(sys))
  
  for (key, value) in kwargs
    setproperty!(m, key, value)
  end
  
  return m
end

get_parent(obj::ModelParams) = getfield(obj, :parent)
get_defs(obj::ModelParams) = getfield(obj, :defs)

function Base.getproperty(x::ModelParams, var::Symbol)
    parent = get_parent(x)
    defs = get_defs(x)

    sym = getproperty(parent, var)

    if typeof(sym) <: System
      return ModelParams(sym, defs)
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

function Base.setproperty!(x::ModelParams, var::Symbol, val)
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

    if (sym isa System) & (val isa ModelParams)

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



function Base.fieldnames(x::ModelParams)
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



function Base.isequal(x::ModelParams, y::ModelParams)
  
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
name it had on its parent, enabling pretty tree printouts of `ModelParams` instances.
"""
struct ParamsNode
    name::Symbol
    value::Any
end

AbstractTrees.children(x::ModelParams) =
    [ParamsNode(n, getproperty(x, n)) for n in fieldnames(x)]

AbstractTrees.children(n::ParamsNode) =
    n.value isa ModelParams ? AbstractTrees.children(n.value) : ()

function AbstractTrees.printnode(io::IO, x::ModelParams) 
  parent =  get_parent(x)
  component_type = ModelingToolkit.get_component_type(parent)
  print(io, component_type.name)
end

function AbstractTrees.printnode(io::IO, n::ParamsNode)
    if n.value isa ModelParams
        print(io, n.name)
    else
        print(io, n.name, ": ", n.value)
    end
end

Base.show(io::IO, ::MIME"text/plain", x::ModelParams) =
    AbstractTrees.print_tree(io, x)

PMapDict = Dict{SymbolicUtils.BasicSymbolicImpl.var"typeof(BasicSymbolicImpl)"{SymReal}, SymbolicUtils.BasicSymbolicImpl.var"typeof(BasicSymbolicImpl)"{SymReal}}

"""
    pmap(model::System, pars::ModelParams)

Return a parameter map suitable for passing to `ODEProblem`, `update!` or `SciMLBase.remake`.
"""
pmap(model::System, pars::ModelParams) = PMapDict(model => pars)

"""
    Pair(model::System, pars::ModelParams)

Return a parameter map suitable for passing to `ODEProblem`, `update!` or `SciMLBase.remake`.
"""
function Base.Pair(model::System, pars::ModelParams)

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
function Base.Dict(x::ModelParams)

  children = Pair[] 

  for nm in fieldnames(x)

      prop = getproperty(x, nm)
      if typeof(prop) <: ModelParams
        val = Dict(prop)
      else
        val = prop
      end
      push!(children, nm => val)
    
  end

  return Dict(children)
end


function Base.setproperty!(x::ModelParams, dict::Dict)
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


function Base.setproperty!(dict::Dict, x::ModelParams, sys::System)
  for nm in fieldnames(x)
    prop = getproperty(x, nm)
    if prop isa ModelParams
      setproperty!(dict, prop, getproperty(sys, nm))
    else
      dict[getproperty(sys, nm)] = prop
    end
  end
end


function Base.copy(x::ModelParams)
    parent = get_parent(x)
    defs = get_defs(x)

    return ModelParams(parent, copy(defs))
end

# fallback value conversion
convert_value(x) = x
convert_value(x::Missing) = "missing"

"""
    save_parameters(x::ModelParams, filepath::String)

Serialize `x` to a TOML file at `filepath`. 
"""
function save_parameters(x::ModelParams, filepath::String)

  open(filepath, "w") do io
    TOML.print(convert_value, io, Dict(x))
  end

end

"""
    parameters_to_string(x::ModelParams)

Convert `x` to TOML string
"""
function parameters_to_string(x::ModelParams)
  io = IOBuffer()
  TOML.print(convert_value, io, Dict(x))
  return String(take!(io))
end

"""
    load_parameters(filepath::String, T::Type)

Read a TOML file written by `save_parameters` and return a new instance of `T` with
the stored values applied.
"""
function load_parameters(filepath::String, model::Function)

  x = ModelParams(model)
  setproperty!(x, TOML.parsefile(filepath))

  return x
end

"""
    string_to_parameters(contents::String, T::Type)

Parse a TOML string and return a new instance of `T`
with the stored values applied.
"""
function string_to_parameters(contents::String, x::ModelParams)

  setproperty!(x, TOML.parse(contents))

  return x
end


"""
    cache(model::System, x::ModelParams; parent=model)

Pre-build a `Vector{ParameterHookWrapper}` of setter functions for every parameter
field in `T`. Pass the returned vector to `update!` to efficiently modify an
`ODEProblem` without rebuilding the setters on each call. `parent` should be the
top-level system when `model` is a subsystem.
"""
function cache(model::System, x::ModelParams; parent=model)

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
    update!(prob::ODEProblem, setters::Vector{ParameterHookWrapper}, param_map::Vector{<:Pair})

Mutate `prob` in-place by applying each setter in `setters` whose parameter appears in
`param_map`. Obtain `setters` from `cache` and `param_map` from `Base.Pair(model, pars)`
or `pmap`. Returns `prob`.
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


function SciMLBase.remake(prob::ODEProblem, setters::Vector{SymbolicIndexingInterface.ParameterHookWrapper}, param_dict::PMapDict)
    prob′ = SciMLBase.remake(prob; p = copy(prob.p)) #NOTE: if p is not set to a copy then p maintains the original reference
    update!(prob′, setters, param_dict)
    # return SciMLBase.remake(prob′) # Note: using remake a 2nd time could be implemented to provide initialization for solvable parameters, see example below...
    return prob′
end


macro model_params(expr)
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

    # Reconstruct as ModelParams(ModelType; kwargs...)
    return :(ModelParams($model_type; $(processed_args...)))
end

end # module ModelingToolkitParameters
