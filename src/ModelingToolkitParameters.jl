module ModelingToolkitParameters
using ModelingToolkit
using SymbolicIndexingInterface
using Symbolics
using SciMLBase
using InteractiveUtils: clipboard
using JuliaFormatter: format_text
using TOML

export  Params, params, pmap, cache, update!

abstract type Params end

params(model::ModelingToolkit.Model, args...) = params(model.f, args...; stripname=true)

function params(model::Function, globals::Union{Function, Nothing} = nothing; stripname=false, parent::Module=parentmodule(model), defaults=NamedTuple())

  name = string(model)
  if stripname
    name = name[3:end-2]
  end

  # Generate the struct name: FunctionName -> FunctionNameParams
  struct_name = Symbol(name * "Params")

  # The strategy: We'll generate code that:
  # 1. Defines the original function
  # 2. Creates a temporary instance to extract parameters
  # 3. Generates the struct based on those parameters

  # Create a temporary instance with a dummy name
  @named temp_instance = model(; defaults...)

  # Get the parameters from the system
  pars = ModelingToolkit.get_ps(temp_instance)
  systems = ModelingToolkit.get_systems(temp_instance)
  

  if !isnothing(globals)
    @named g = globals()
    gs = ModelingToolkit.get_ps(g)
    append!(pars, gs)
  end
    
  # Build the struct fields
  exprs = String[]

  if !isempty(pars)
    push!(exprs, "# parameters")
  end

  for par in pars
      # Get the parameter name (without the system prefix)
      par_name = Symbol(ModelingToolkit.getname(par))

      # Get the parameter type
      par_type = Symbolics.symtype(par)

      # Get default value if available
      defaults = ModelingToolkit.get_defaults(temp_instance)
      default_val = get(defaults, par, nothing)

      # Create the field expression with type and default

      if default_val !== nothing
          push!(exprs, "$par_name::$par_type = $default_val")
      else
          # If no default, just use type annotation
          push!(exprs, "$par_name::$par_type")
      end
  end


  add_comment = true
  for system in systems
      # Get the parameter name (without the system prefix)
      system_name = Symbol(ModelingToolkit.getname(system))
      system_type = ModelingToolkit.get_component_type(system).name
      struct_type = Symbol(string(system_type) * "Params")

      if isdefined(parent, struct_type)
        if add_comment
          push!(exprs, "# systems")
          add_comment = false
        end

        names = fieldnames(getproperty(parent, struct_type))
        defs = ModelingToolkit.defaults(system)
        values = map(x->getindex(defs, Sym{Real}(x)), names)

        args = String[]
        for (n,v) in zip(names, values)
          push!(args, "$n = $v")
        end

        push!(exprs, "$system_name::$struct_type = $struct_type($(join(args, ",")))")
      else
        @warn "$system_name::$struct_type definition not available, skipping"
      end
  end



  # Generate the struct definition
  struct_def = format_text("""
  Base.@kwdef mutable struct $struct_name <: Params
    $(join(exprs, "\n"))
  end
  """)

  clipboard(struct_def)
  print(struct_def)
  
  return nothing
end


# (::Type{T})(globals; kwargs...) where T <: Params = T(;globals, kwargs...)

# build a parameter map ------------------------------
pmap(model::ODESystem, pars::T) where T <: Params  = model => pars

function Base.Pair(model::ODESystem, pars::T) where T <: Params  

  prs = Pair[]
  for nm in fieldnames(T)
    if hasproperty(model, nm)
      x = getproperty(model,nm) => getproperty(pars,nm)
      if x isa Vector
        append!(prs, x)
      else
        push!(prs, x)
      end
    end
  end

  return prs
end





# support for saving ----------------------------
function Base.Dict(x::T) where T <: Params 

  children = Pair[] 

  for nm in fieldnames(T)

      prop = getproperty(x, nm)
      if typeof(prop) <: Params
        val = Dict(prop)
      else
        val = prop
      end
      push!(children, nm => val)
    
  end

  return Dict(children)
end

function Base.setproperty!(x::T, dict::Dict) where T <: Params
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
# function Base.setproperty!(sys::ODESystem, x::T) where T <: Params
#   defs = ModelingToolkit.defaults(sys)
#   setproperty!(defs, x, sys)
# end


function Base.setproperty!(dict::Dict, x::T, sys::ODESystem) where T <: Params
  for nm in fieldnames(T)
    prop = getproperty(x, nm)
    if prop isa Params
      setproperty!(dict, prop, getproperty(sys, nm))
    else
      dict[getproperty(sys, nm)] = prop
    end
  end
end


function Base.copy(x::T) where T
  
  kwargs = Pair[]
  for nm in fieldnames(T)

    prop = getproperty(x,nm)
    push!(kwargs, nm => copy(prop))

  end

  return T(NamedTuple(kwargs)...)
end

# fallback value conversion
convert_value(x) = x

function save_parameters(x::T, filepath::String) where T <: Params

  open(filepath, "w") do io
    TOML.print(convert_value, io, Dict(x))
  end

end

function parameters_to_string(x::T) where T <: Params
  io = IOBuffer()
  TOML.print(convert_value, io, Dict(x))
  return String(take!(io))
end

function load_parameters(filepath::String, T::Type)

  t = T()

  setproperty!(t, TOML.parsefile(filepath))

  return t
end

function string_to_parameters(contents::String, T::Type)

  t = T()

  setproperty!(t, TOML.parse(contents))

  return t
end


# build setters cache --------------------------
function cache(model::ODESystem, T::Type{<:Params}; parent=model)

  prs = SymbolicIndexingInterface.ParameterHookWrapper[]
  for nm in fieldnames(T)
    if hasproperty(model, nm)
      p = getproperty(model,nm)
      if p isa System 
        ps = cache(p, fieldtype(T, nm); parent)
        append!(prs, ps)
      else
        @show p
        setter = setp(parent, p)
        push!(prs, setter)
      end
    end
  end

  return prs
end


# Update an ODEProblem with modified parameter values
function update!(prob::ODEProblem, setters::Vector{SymbolicIndexingInterface.ParameterHookWrapper}, param_map::Vector{<:Pair})

  # Create a dictionary for fast lookup
  param_dict = Dict(param_map)

  # Apply each setter by matching its parameter to the param_dict
  for setter in setters
    # Get the parameter that this setter operates on
    param = setter.original_index

    # If this parameter is in our update map, apply it
    if haskey(param_dict, param)
      setter(prob, param_dict[param])
    end
  end

  return prob
end


function SciMLBase.remake(prob::ODEProblem, setters::Vector{SymbolicIndexingInterface.ParameterHookWrapper}, param_map::Vector{<:Pair})
    prob′ = SciMLBase.remake(prob)
    update!(prob′, setters, param_map)
    # return SciMLBase.remake(prob′) # Note: using remake a 2nd time could be implemented to provide initialization for solvable parameters, see example below...
    return prob′
end

#=
pars = @parameters begin
    total = missing, [guess=0]
    p = 10
end
vars = @variables begin
    x(t)=0
    y(t)=1
end
eqs = [
    D(x) ~ y*total
    x + y + p ~ total
]
@mtkcompile sys = System(eqs, t, vars, pars)
prob = ODEProblem(sys, [], (0, 1))
prob.ps[total] # = 11

# --------------
prob2 = remake(prob) # make a copy
pf(prob2, 20) # set the value
prob2.ps[sys.total] # =11 total not yet updated
prob3 = remake(prob2)  # run initialization
prob3.ps[sys.total] # = 21 total now updated
=#

end # module ModelingToolkitParameters
