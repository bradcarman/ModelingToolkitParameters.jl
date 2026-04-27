module ModelingToolkitParameters
using ModelingToolkit
using SymbolicIndexingInterface
using Symbolics
using SciMLBase
using InteractiveUtils: clipboard
using JuliaFormatter: format_text
using TOML
using AbstractTrees

export  Params, params, pmap, cache, update!, build_params
export ModelParams, get_parent, get_defs

"""
    Params

Abstract supertype for all generated parameter structs.
"""
abstract type Params end

struct ModelParams <: Params
    parent::System
    defs::Dict
end

function ModelParams(Model::Function)
  @named sys = Model()
  return ModelParams(sys)
end

ModelParams(sys::System) = ModelParams(ModelingToolkit.toggle_namespacing(sys, false), ModelingToolkit.initial_conditions(sys))
get_parent(obj::ModelParams) = getfield(obj, :parent)
get_defs(obj::ModelParams) = getfield(obj, :defs)

function Base.getproperty(x::ModelParams, var::Symbol)
    parent = get_parent(x)
    defs = get_defs(x)

    sym = getproperty(parent, var)

    if typeof(sym) <: System
      return ModelParams(sym, defs)
    else
      return Symbolics.value(defs[sym])
    end
end

function Base.setproperty!(x::ModelParams, var::Symbol, val)
    parent = get_parent(x)
    defs = get_defs(x)

    sym = getproperty(parent, var)

    defs[sym] = val

    return nothing
end

function Base.fieldnames(x::ModelParams)
  sys = get_parent(x)

  names = Symbol[]

  for par in ModelingToolkit.get_ps(sys)
    

    scope = ModelingToolkit.getmetadata(par, ModelingToolkit.SymScope, ModelingToolkit.LocalScope())
    scope isa ModelingToolkit.GlobalScope && continue

    if !ModelingToolkit.isinitial(par)
      push!(names, Symbol(ModelingToolkit.getname(par)))
    end
  end

  for sub in ModelingToolkit.get_systems(sys)
    ps = ModelingToolkit.get_ps(sub)
    ss = ModelingToolkit.get_systems(sub)
    name = Symbol(ModelingToolkit.getname(sub))
    if !isempty(ps) | !isempty(ss)
      push!(names, name)
    end
  end

  return names
end












































function Base.isequal(x::T1, y::T2) where {T1<:Params, T2<:Params}
  
  names1 = fieldnames(T1)
  names2 = fieldnames(T2)
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

@static if pkgversion(ModelingToolkit) < v"11"
  # support for the @mtkmodel macro
  params(model::ModelingToolkit.Model, args...) = params(model.f, args...; stripname=true)
end

"""
    params(model::Function, globals=nothing; stripname=false, parent=parentmodule(model), defaults=NamedTuple())

Inspect a ModelingToolkit component function and generate the corresponding `Params` struct
definition. The struct definition is printed to the REPL and copied to the clipboard.
`globals` is an optional second component function whose parameters are appended as
top-level fields. `defaults` can be used to pass keyword arguments when instantiating
the component for introspection.  Use `parent` to specify the module where child `System` 
definitions can be found if located in a different module from `model`.
"""
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
      defaults = if isdefined(ModelingToolkit, :initial_conditions) # only defined on MTK v11, not v10 and below
          ModelingToolkit.initial_conditions(temp_instance)
      else
          ModelingToolkit.defaults(temp_instance)
      end
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
        defs = if isdefined(ModelingToolkit, :initial_conditions) # only defined on MTK v11, not v10 and below
            ModelingToolkit.initial_conditions(system)
        else
            ModelingToolkit.defaults(system)
        end
        sub_pars = ModelingToolkit.get_ps(system)
        values = map(names) do nm
          par_idx = findfirst(p -> Symbol(ModelingToolkit.getname(p)) == nm, sub_pars)
          par_idx !== nothing ? get(defs, sub_pars[par_idx], nothing) : nothing
        end

        args = String[]
        for (n,v) in zip(names, values)
          if !isnothing(v)
            push!(args, "$n = $v")
          end
        end

        push!(exprs, "$system_name::$struct_type = $struct_type($(join(args, ",")))")
      else
        @warn "$system_name::$struct_type definition not available in $parent, skipping"
      end
  end



  # Generate the struct definition
  struct_def = format_text("""
  Base.@kwdef mutable struct $struct_name <: Params
    $(join(exprs, "\n"))
  end
  """)

  # use try/catch as clipboard is not always available (like on CI: ERROR: LoadError: no clipboard command found, please install xsel or xclip or wl-clipboard)
  try clipboard(struct_def) catch end
  print(struct_def)
  
  return nothing
end


"""
    build_params(model::Function; eval_module::Module = Module())

Instantiate the component once via `@named sys = model()` and return the `Params`
subtype produced by `build_params(sys; eval_module)`.
"""
function build_params(model::Function; eval_module::Module = Module(), globals=Pair[])
    @named sys = model()
    return _build_params_type(sys, _override_map(sys), Symbol[], eval_module, globals)
end


# (::Type{T})(globals; kwargs...) where T <: Params = T(;globals, kwargs...)

"""
    build_params(model::System; eval_module::Module = Module())

Build and return a `Params` subtype (constructor) that mirrors the hierarchy of a
(possibly compiled) `System`. Each subsystem becomes a field whose type is built
recursively and defaulted to its own default constructor. Top-level parameters
become keyword-argument fields defaulted to the system's declared defaults;
parameters with no declared default become required keyword arguments. Overrides
specified in the root system's `initial_conditions` (e.g., `source.V => 20`) are
propagated down to the matching subsystem field. The returned type is generated
with `Base.@kwdef`, so instances are constructed by keyword, e.g.
`T(; field1 = value1, ...)`.

The generated struct (and any nested sub-structs) are `Core.eval`'d into
`eval_module`. The default is a fresh anonymous module per call, which is safe but
opaque. To make the generated type part of *your* package's precompile image, pass
your module explicitly at the call site:

    MyParams = build_params(MyModel; eval_module = @__MODULE__)
"""
function build_params(model::System; eval_module::Module = Module(), globals=Pair[])
    # Walk up to the root hierarchical system (pre-compile) to recover subsystems
    root = model
    while true
        p = ModelingToolkit.get_parent(root)
        p === nothing && break
        root = p
    end
    return _build_params_type(root, _override_map(root), Symbol[], eval_module, globals)
end

# Build a Dict{Symbol, Any} from a system's defaults/initial_conditions,
# keyed by the fully namespaced parameter name (e.g. :source₊V).
function _override_map(sys::System)
    defs = if isdefined(ModelingToolkit, :initial_conditions)
        ModelingToolkit.initial_conditions(sys)
    else
        ModelingToolkit.defaults(sys)
    end
    out = Dict{Symbol, Any}()
    for (k, v) in defs
        out[Symbol(ModelingToolkit.getname(k))] = v
    end
    return out
end

function _build_params_type(sys::System, override_map::Dict{Symbol, Any}, prefix::Vector{Symbol}, eval_module::Module, globals=Pair[])
    # Reuse an already-built `Params` subtype for this component within
    # `eval_module`. This guarantees a single canonical type per component across
    # all calls (including recursive ones), so an instance built via the
    # standalone `DamperParams` is the same type the parent struct's
    # `damper::DamperParams` field expects. The cache key is a hidden binding
    # rather than the public-facing name (e.g. `:DamperParams`) to sidestep
    # Julia's top-level global pre-declaration: `DamperParams = build_params(...)`
    # reserves `DamperParams` as a non-const global before the RHS runs, which
    # prevents `Core.eval` from defining a struct under that exact name.
    base_name = _component_params_name(sys)
    cache_name = base_name === :BuiltParams ?
        nothing : Symbol("__bp_cache_", base_name, "__")
    if cache_name !== nothing && isdefined(eval_module, cache_name)
        existing = getfield(eval_module, cache_name)
        if existing isa Type && existing <: Params
            return existing
        end
    end

    field_exprs = Expr[]
    for (var,val) in globals
      push!(field_exprs, Expr(:(=), Expr(:(::), var, typeof(val)), val))
    end

    local_defs = if isdefined(ModelingToolkit, :initial_conditions)
        ModelingToolkit.initial_conditions(sys)
    else
        ModelingToolkit.defaults(sys)
    end

    # Top-level parameters
    for par in ModelingToolkit.get_ps(sys)
       @show par
        # Skip globally scoped parameters; they belong to the outer scope and would
        # collide if added per-component.
        scope = ModelingToolkit.getmetadata(par, ModelingToolkit.SymScope, ModelingToolkit.LocalScope())
        scope isa ModelingToolkit.GlobalScope && continue

        par_name = Symbol(ModelingToolkit.getname(par))
        par_type = Symbolics.symtype(par)
        full_name = isempty(prefix) ? par_name : Symbol(join([prefix..., par_name], "₊"))
        raw_default = if haskey(override_map, full_name)
            override_map[full_name]
        elseif haskey(local_defs, par)
            local_defs[par]
        elseif ModelingToolkit.hasdefault(par)
            # `missing` defaults aren't stored in `initial_conditions`, but are
            # recoverable via `getdefault`.
            ModelingToolkit.getdefault(par)
        else
            nothing
        end
        default_val = raw_default === nothing || raw_default === missing ?
            raw_default : Symbolics.value(raw_default)

        @show par_name par_type full_name raw_default default_val
        if default_val === missing
            field_type = Union{Missing, par_type}
            push!(field_exprs, Expr(:(=), Expr(:(::), par_name, field_type), missing))
        elseif default_val isa par_type
            push!(field_exprs, Expr(:(=), Expr(:(::), par_name, par_type), default_val))
        else
            push!(field_exprs, Expr(:(::), par_name, par_type))
        end
    end

    # Subsystems, built recursively (sharing the same eval_module)
    for sub in ModelingToolkit.get_systems(sys)
        sub_name = Symbol(ModelingToolkit.getname(sub))
        SubT = _build_params_type(sub, override_map, [prefix..., sub_name], eval_module)
        if !isnothing(SubT)
          push!(field_exprs, Expr(:(=), Expr(:(::), sub_name, SubT), Expr(:call, SubT)))
        end
    end

    if !isempty(field_exprs)
      type_name = gensym(base_name)
      # Interpolate `Params` as a Type (not as the symbol :Params) so the generated
      # code does not depend on `Params` being in scope wherever the struct is eval'd.
      struct_expr = Expr(:struct, true,
          Expr(:(<:), type_name, Params),
          Expr(:block, field_exprs...))
      kwdef_expr = Expr(:macrocall,
          Expr(:., :Base, QuoteNode(Symbol("@kwdef"))),
          LineNumberNode(0, :none),
          struct_expr)
      Core.eval(eval_module, kwdef_expr)
      T = Base.invokelatest(getfield, eval_module, type_name)

      # Register the built type under the hidden cache binding so subsequent
      # calls for the same component (including recursive ones) reuse it.
      if cache_name !== nothing
          Core.eval(eval_module, Expr(:const, Expr(:(=), cache_name, T)))
      end

      return T
    else
      return nothing
    end
end

# Derive a human-readable base name for the generated struct from the
# originating component's function name, e.g. RCModel -> :RCModelParams.
# Falls back to :BuiltParams if the component type is unavailable.
function _component_params_name(sys::System)
    try
        cname = String(ModelingToolkit.get_component_type(sys).name)
        return Symbol(cname * "Params")
    catch
        return :BuiltParams
    end
end

# Strip the gensym decoration `##Name#N` to recover `Name` for display.
function _display_typename(::Type{T}) where {T<:Params}
    s = String(nameof(T))
    m = match(r"^##(.+)#\d+$", s)
    return m === nothing ? s : m.captures[1]
end

"""
    ParamsNode(name, value)

Internal wrapper used by the `AbstractTrees` integration so each field carries the
name it had on its parent, enabling pretty tree printouts of `Params` instances.
"""
struct ParamsNode
    name::Symbol
    value::Any
end

AbstractTrees.children(x::Params) =
    [ParamsNode(n, getproperty(x, n)) for n in propertynames(x)]

AbstractTrees.children(n::ParamsNode) =
    n.value isa Params ? AbstractTrees.children(n.value) : ()

AbstractTrees.printnode(io::IO, x::T) where {T<:Params} = 
    print(io, _display_typename(T))

function AbstractTrees.printnode(io::IO, n::ParamsNode)
    if n.value isa Params
        print(io, n.name)
    else
        print(io, n.name, ": ", n.value)
    end
end

Base.show(io::IO, ::MIME"text/plain", x::Params) =
    AbstractTrees.print_tree(io, x)


"""
    pmap(model::System, pars::Params)

Return a parameter map suitable for passing to `ODEProblem`, `update!` or `SciMLBase.remake`.
"""
pmap(model::System, pars::T) where T <: Params  = model => pars


"""
    Pair(model::System, pars::T) where T <: Params  

Return a parameter map suitable for passing to `ODEProblem`, `update!` or `SciMLBase.remake`.
"""
function Base.Pair(model::System, pars::T) where T <: Params  

  prs = Pair[]
  for nm in fieldnames()
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


function Base.Pair(model::System, pars::ModelParams)

  prs = Pair[]
  for nm in fieldnames(pars)
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
# function Base.setproperty!(sys::System, x::T) where T <: Params
#   defs = ModelingToolkit.defaults(sys)
#   setproperty!(defs, x, sys)
# end


function Base.setproperty!(dict::Dict, x::T, sys::System) where T <: Params
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

"""
    save_parameters(x::Params, filepath::String)

Serialize `x` to a TOML file at `filepath`. 
"""
function save_parameters(x::T, filepath::String) where T <: Params

  open(filepath, "w") do io
    TOML.print(convert_value, io, Dict(x))
  end

end

"""
    parameters_to_string(x::Params)

Convert `x` to TOML string
"""
function parameters_to_string(x::T) where T <: Params
  io = IOBuffer()
  TOML.print(convert_value, io, Dict(x))
  return String(take!(io))
end

"""
    load_parameters(filepath::String, T::Type)

Read a TOML file written by `save_parameters` and return a new instance of `T` with
the stored values applied.
"""
function load_parameters(filepath::String, T::Type)

  t = T()

  setproperty!(t, TOML.parsefile(filepath))

  return t
end

"""
    string_to_parameters(contents::String, T::Type)

Parse a TOML string and return a new instance of `T`
with the stored values applied.
"""
function string_to_parameters(contents::String, T::Type)

  t = T()

  setproperty!(t, TOML.parse(contents))

  return t
end


"""
    cache(model::System, T::Type{<:Params}; parent=model)

Pre-build a `Vector{ParameterHookWrapper}` of setter functions for every parameter
field in `T`. Pass the returned vector to `update!` to efficiently modify an
`ODEProblem` without rebuilding the setters on each call. `parent` should be the
top-level system when `model` is a subsystem.
"""
function cache(model::System, T::Type{<:Params}; parent=model)

  prs = SymbolicIndexingInterface.ParameterHookWrapper[]
  for nm in fieldnames(T)
    if hasproperty(model, nm)
      p = getproperty(model,nm)
      if p isa System 
        ps = cache(p, fieldtype(T, nm); parent)
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
    prob′ = SciMLBase.remake(prob; p = copy(prob.p)) #NOTE: if p is not set to a copy then p maintains the original reference
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
