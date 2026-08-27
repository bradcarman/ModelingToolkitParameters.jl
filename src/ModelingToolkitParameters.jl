module ModelingToolkitParameters
using ModelingToolkit
using SymbolicIndexingInterface
using Symbolics
using SciMLBase
using InteractiveUtils: clipboard
using TOML
using AbstractTrees
using Logging

export MTKParams, get_parent, get_defs, pdict, cache, update!, transfer, compare, MTKParamsDiff, @mtkparams, save_parameters, load_parameters, show_missing!, hide_missing!

"""
    MTKParamsOptions()

Mutable display-option flags for an [`MTKParams`](@ref) tree. A single instance is
shared (by reference) across a whole `MTKParams` tree — every sub-`MTKParams`
returned by `getproperty` carries the same `options` object as its parent — so
toggling a flag anywhere in the tree (see [`show_missing!`](@ref)/
[`hide_missing!`](@ref)) changes how the *entire* tree prints.
"""
mutable struct MTKParamsOptions
  # Whether `nothing`/`missing` leaf values are printed in the tree display.
  show_missing::Bool
end

MTKParamsOptions() = MTKParamsOptions(true)

Base.copy(o::MTKParamsOptions) = MTKParamsOptions(o.show_missing)

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

Use [`pdict`](@ref) (or `model => pars`) to convert a `MTKParams` into the
parameter map expected by `ODEProblem`/`SciMLBase.remake`, and [`cache`](@ref) +
[`update!`](@ref) for fast in-place updates.

The printed tree display shows `nothing`/`missing` leaf values by default; call
[`hide_missing!`](@ref)/[`show_missing!`](@ref) to toggle this for the whole tree.

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
    # Parameters of *this* system that an enclosing parent binds to an *unresolved*
    # value (`missing`) — Dyad's `p = missing, [guess=...]` initialization params.
    # Unlike `bound`, these stay tunable and visible; captured here only so their
    # current value reads back as `missing` rather than `nothing` (the binding lives
    # on the parent, so a child examined in isolation cannot recover it).
    unresolved::Set{Symbol}
    # Display-option flags, shared by reference across the whole tree. See
    # `MTKParamsOptions`.
    options::MTKParamsOptions
end

# Backward-compatible constructors: no parent-imposed bindings on this system.
# `defs` is left untyped so any AbstractDict (e.g. `initial_conditions`'s
# AtomicArrayDict) is converted by the inner constructor, as before.
MTKParams(parent::System, defs) = MTKParams(parent, defs, Dict{Symbol, Any}(), Set{Symbol}(), MTKParamsOptions())
MTKParams(parent::System, defs, bound) = MTKParams(parent, defs, bound, Set{Symbol}(), MTKParamsOptions())
MTKParams(parent::System, defs, bound, unresolved) = MTKParams(parent, defs, bound, unresolved, MTKParamsOptions())

function MTKParams(Model::Function; kwargs...)
  @named sys = Model()
  return MTKParams(sys; kwargs...)
end

function MTKParams(sys::System; kwargs...)
  #NOTE: sys must be not structuraly simplified because we need access to the sub-systems
  @assert !ModelingToolkit.iscomplete(sys) "`MTKParams` cannot accept a structualy simplified system, please use @named only"
  sys_nn = ModelingToolkit.toggle_namespacing(sys, false)
  m = MTKParams(sys_nn, ModelingToolkit.initial_conditions(sys), Dict{Symbol, Any}(), own_unresolved_names(sys_nn))
  
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

"""
    get_unresolved(p::MTKParams) -> Set{Symbol}

Return the names of parameters of `p`'s system that an *enclosing* parent binds to
an unresolved value (`missing`) — solved during initialization (see
[`parent_unresolved_names`](@ref)). These stay tunable and visible, but read back
as `missing` until overridden.
"""
get_unresolved(obj::MTKParams) = getfield(obj, :unresolved)

"""
    get_options(p::MTKParams) -> MTKParamsOptions

Return `p`'s display-option flags. Shared by reference across the whole tree `p`
belongs to — see [`MTKParamsOptions`](@ref).
"""
get_options(obj::MTKParams) = getfield(obj, :options)

"""
    show_missing!(p::MTKParams)

Turn on display of `nothing`/`missing` leaf values when printing `p` (the
default). Applies to the whole `MTKParams` tree `p` belongs to, since display
options are shared across it — see [`hide_missing!`](@ref).
"""
show_missing!(x::MTKParams) = (get_options(x).show_missing = true; nothing)

"""
    hide_missing!(p::MTKParams)

Turn off display of `nothing`/`missing` leaf values when printing `p`. Applies to
the whole `MTKParams` tree `p` belongs to, since display options are shared across
it — see [`show_missing!`](@ref).
"""
hide_missing!(x::MTKParams) = (get_options(x).show_missing = false; nothing)

function Base.getproperty(x::MTKParams, var::Symbol)
    parent = get_parent(x)
    defs = get_defs(x)

    sym = getproperty(parent, var)

    if typeof(sym) <: System
      unresolved = union(parent_unresolved_names(parent, var), own_unresolved_names(sym))
      return MTKParams(sym, defs, parent_bindings(parent, var), unresolved, get_options(x))
    else
      if !haskey(defs, sym)
        if ModelingToolkit.hasdefault(sym)
          return ModelingToolkit.getdefault(sym)
        elseif var in get_unresolved(x)
          # Parent binds this parameter to an unresolved value (`missing`): it is
          # solved during initialization. It stays tunable, but its current value
          # is `missing`, not `nothing` (which means "unspecified").
          return missing
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
in the parameter object, the tree display, `pdict`, or `cache`. A plain numeric
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
  each_parent_binding(parent, subname) do local_name, v
    is_unresolved_binding(v) && return  # unresolved bindings stay tunable
    res[local_name] = v
  end
  return res
end

"""
    parent_unresolved_names(parent::System, subname::Symbol) -> Set{Symbol}

Return the direct parameters of sub-system `subname` that `parent` binds to an
*unresolved* value (`missing`) — Dyad's `p = missing, [guess=...]` initialization
parameters. These are the ones [`parent_bindings`](@ref) deliberately skips (they
stay tunable), captured separately so `MTKParams` can report their value as
`missing` rather than `nothing`.
"""
function parent_unresolved_names(parent::System, subname::Symbol)
  res = Set{Symbol}()
  each_parent_binding(parent, subname) do local_name, v
    is_unresolved_binding(v) && push!(res, local_name)
  end
  return res
end

"""
    own_unresolved_names(sys::System) -> Set{Symbol}

Return the direct parameters of `sys` that `sys` *itself* binds to an unresolved
value (`missing`) — Dyad's `p = missing, [guess=...]` initialization parameters
declared directly on `sys`, as recorded under a plain (non-namespaced) key in
`sys`'s own binding registry.

This is distinct from [`parent_unresolved_names`](@ref), which only recovers a
`missing` marker that an *enclosing* system re-binds under a namespaced key
(`subname₊param`). Dyad does not always lift a component's own `missing` default
into the parent's registry that way — it is frequently left as a plain entry in
the component's own registry instead — so `MTKParams` must check both sources when
descending into a sub-system, or such parameters read back as `nothing` (meaning
"unspecified") rather than `missing` (meaning "unresolved, solved at
initialization").
"""
function own_unresolved_names(sys::System)
  ModelingToolkit.has_bindings(sys) || return Set{Symbol}()
  res = Set{Symbol}()
  for (k, v) in ModelingToolkit.get_bindings(sys)
    name = string(ModelingToolkit.getname(k))
    occursin(ModelingToolkit.NAMESPACE_SEPARATOR, name) && continue
    is_unresolved_binding(v) && push!(res, Symbol(name))
  end
  return res
end

# Walk `parent`'s binding registry, invoking `f(local_name::Symbol, value)` for each
# entry that binds a *direct* parameter of sub-system `subname` (namespaced key
# `subname₊param`; deeper names belong to `subname`'s own descendants). Shared by
# `parent_bindings` (resolved) and `parent_unresolved_names` (unresolved) so the
# prefix-matching logic lives in one place.
function each_parent_binding(f, parent::System, subname::Symbol)
  ModelingToolkit.has_bindings(parent) || return
  prefix = string(subname) * ModelingToolkit.NAMESPACE_SEPARATOR
  for (k, v) in ModelingToolkit.get_bindings(parent)
    name = string(ModelingToolkit.getname(k))
    startswith(name, prefix) || continue
    local_name = chopprefix(name, prefix)
    occursin(ModelingToolkit.NAMESPACE_SEPARATOR, local_name) && continue
    f(Symbol(local_name), v)
  end
  return
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
    Absent

Sentinel marking a path that exists on one side of a [`compare`](@ref) but not
the other (e.g. `pars1` and `pars2` were built from different model variants).
Distinct from a parameter that exists but is unset (`nothing`) or unresolved
(`missing`).
"""
struct Absent end
const _ABSENT = Absent()

"""
    MTKParamsDiffRow(path, value1, value2)

One row of a [`MTKParamsDiff`](@ref): `path` is the dotted parameter path
(e.g. `"seat.spring.initial_stretch"`), `value1`/`value2` are the differing
values from each side (or `Absent` if the path doesn't exist on that side).
"""
struct MTKParamsDiffRow
  path::String
  value1::Any
  value2::Any
end

"""
    MTKParamsDiff(rows::Vector{MTKParamsDiffRow})

Result of [`compare`](@ref): the parameter paths where two `MTKParams` trees
differ. Displays as a table (`path`, `pars1` value, `pars2` value); if `rows`
is empty, displays as "No differences.".
"""
struct MTKParamsDiff
  rows::Vector{MTKParamsDiffRow}
end

format_diff_value(::Absent) = "–"
format_diff_value(v) = sprint(show, v; context = :compact => true)

function Base.show(io::IO, ::MIME"text/plain", d::MTKParamsDiff)
  if isempty(d.rows)
    print(io, "No differences.")
    return
  end

  header = ("Parameter", "pars1", "pars2")
  paths = [r.path for r in d.rows]
  vals1 = [format_diff_value(r.value1) for r in d.rows]
  vals2 = [format_diff_value(r.value2) for r in d.rows]

  w1 = maximum(length, (header[1], paths...))
  w2 = maximum(length, (header[2], vals1...))
  w3 = maximum(length, (header[3], vals2...))

  println(io, rpad(header[1], w1), "  ", rpad(header[2], w2), "  ", rpad(header[3], w3))
  println(io, "-"^w1, "  ", "-"^w2, "  ", "-"^w3)
  for (p, v1, v2) in zip(paths, vals1, vals2)
    println(io, rpad(p, w1), "  ", rpad(v1, w2), "  ", rpad(v2, w3))
  end
end

"""
    compare(pars1::MTKParams, pars2::MTKParams) -> MTKParamsDiff

Compare two `MTKParams` trees and return an [`MTKParamsDiff`](@ref) listing
every parameter path where the two disagree (by `isequal`), along with the
value on each side. Recurses into sub-systems; the path shown for each row is
the dotted name (e.g. `"seat.spring.initial_stretch"`).

`pars1` and `pars2` need not expose exactly the same parameters (e.g. built
from different model variants): the union of both trees' paths is walked, and
a path present on only one side shows up as a diff row with the other side
marked `Absent`.

If there are no differences, the returned `MTKParamsDiff` displays as
"No differences.".
"""
function compare(pars1::MTKParams, pars2::MTKParams)
  rows = MTKParamsDiffRow[]
  compare_into!(rows, "", pars1, pars2)
  return MTKParamsDiff(rows)
end

function compare(pars::MTKParams, prob::ODEProblem)
  rows = MTKParamsDiffRow[]
  ipars = transfer(pars, prob)
  compare_into!(rows, "", pars, ipars)
  return MTKParamsDiff(rows)
end

function compare_into!(rows::Vector{MTKParamsDiffRow}, path::String, x, y)
  names1 = x isa MTKParams ? propertynames(x) : Symbol[]
  names2 = y isa MTKParams ? propertynames(y) : Symbol[]

  for nm in union(names1, names2)
    subpath = isempty(path) ? string(nm) : path * "." * string(nm)

    v1 = (x isa MTKParams && hasproperty(x, nm)) ? getproperty(x, nm) : _ABSENT
    v2 = (y isa MTKParams && hasproperty(y, nm)) ? getproperty(y, nm) : _ABSENT

    if v1 isa MTKParams || v2 isa MTKParams
      compare_into!(rows, subpath, v1, v2)
    elseif !isequal(v1, v2)
      push!(rows, MTKParamsDiffRow(subpath, v1, v2))
    end
  end
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

function AbstractTrees.children(x::MTKParams)
  show_missing = get_options(x).show_missing
  nodes = ParamsNode[]
  for n in propertynames(x)
    val = getproperty(x, n)
    # Hide unset (`nothing`) and unresolved (`missing`) leaf values when the
    # tree's display options say so (see `hide_missing!`). Sub-`MTKParams`
    # branches are never `nothing`/`missing`, so they are unaffected.
    (!show_missing && (val === nothing || val === missing)) && continue
    push!(nodes, ParamsNode(n, val))
  end
  return nodes
end

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

PDict = Dict{SymbolicUtils.BasicSymbolicImpl.var"typeof(BasicSymbolicImpl)"{SymReal}, SymbolicUtils.BasicSymbolicImpl.var"typeof(BasicSymbolicImpl)"{SymReal}}

"""
    pdict(model::System, pars::MTKParams) -> Dict

Build a `Dict{symbolic_parameter, value}` keyed by the symbolic parameters of
`model`. This is the form accepted by [`update!`](@ref) and the cache-aware
`SciMLBase.remake(prob, setters, param_dict)` method.

For the flat `Vector{Pair}` form expected by `ODEProblem` and the standard
`SciMLBase.remake(prob; p = ...)`, write `model => pars` instead.
"""
pdict(model::System, pars::MTKParams) = PDict(model => pars)

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
    return MTKParams(get_parent(x), copy(get_defs(x)), copy(get_bound(x)), copy(get_unresolved(x)), copy(get_options(x)))
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
together with a parameter map from [`pdict`](@ref), to [`update!`](@ref) or
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
    resolve(val, param_dict::PDict)

Reduce a [`pdict`](@ref) value to the concrete value a setter can write.

A parameter's value is not always concrete: it can be a symbolic expression of *other*
parameters in the same map. Dyad's code generator propagates a parent parameter into a
sub-component by recording the child's initial condition as the parent's symbolic
variable (`source₊medium_data => medium_data`), and defaults may be expressions of
those (`source₊medium₊p_crit => critical_pressure_Pa(source₊medium_data)`). Such chains
can be several levels deep.

`SciMLBase.remake(prob; p = ...)` resolves these itself, but the [`cache`](@ref) setters
write straight into the parameter buffer, so they have to be resolved here first —
otherwise the raw symbolic reaches the buffer and fails to convert to the parameter's
type. Concrete values (the common case) skip substitution entirely.
"""
function resolve(val, param_dict::PDict)
  val = Symbolics.value(val)
  symbolic_type(val) === NotSymbolic() && return val
  return Symbolics.value(symbolic_evaluate(val, param_dict))
end

"""
    update!(prob::ODEProblem,
            setters::Vector{ParameterHookWrapper},
            param_dict::Dict) -> prob

Mutate `prob` in place by applying every setter in `setters` whose target
parameter appears in `param_dict`. `setters` is produced by [`cache`](@ref) and
`param_dict` by [`pdict`](@ref). Values that are symbolic expressions of other
parameters in `param_dict` are resolved first (see [`resolve`](@ref)). Entries with
`missing` values are skipped (the underlying setters do not accept `missing`).
Returns `prob`.
"""
function update!(prob::ODEProblem, setters::Vector{SymbolicIndexingInterface.ParameterHookWrapper}, param_dict::PDict)

  # Apply each setter by matching its parameter to the param_dict
  for setter in setters
    # Get the parameter that this setter operates on
    param = setter.original_index

    # If this parameter is in our update map, apply it
    if haskey(param_dict, param)
      val = resolve(param_dict[param], param_dict)
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
function SciMLBase.remake(prob::ODEProblem, setters::Vector{SymbolicIndexingInterface.ParameterHookWrapper}, param_dict::PDict)
    prob′ = SciMLBase.remake(prob; p = copy(prob.p)) #NOTE: if p is not set to a copy then p maintains the original reference
    update!(prob′, setters, param_dict)
    # return SciMLBase.remake(prob′) # Note: using remake a 2nd time could be implemented to provide initialization for solvable parameters, see example below...
    return prob′
end


"""
    transfer(pars::MTKParams, prob::ODEProblem) -> new_pars::MTKParams

Return a copy of `pars` with every parameter it exposes updated to the value
currently held by `prob` (read via `prob.ps`). `pars` itself is left
unmodified.

This generalizes patterns like
```julia
pars.seat.spring.initial_stretch = prob.ps[sys.seat.spring.initial_stretch]
```
to every parameter `pars` exposes, which is useful for pulling values that
were solved for during `ODEProblem` initialization (e.g. Dyad's
`p = missing, [guess=...]` initialization parameters) back into a `MTKParams`
object.

The model is recovered from `prob.f.sys`. If a parameter `pars` exposes
cannot be read from `prob.ps` (not present on the model, or the value comes
back `missing`), it is skipped with a warning and `new_pars` keeps `pars`'
original value for that field.
"""
function transfer(pars::MTKParams, prob::ODEProblem)
  new_pars = copy(pars)
  transfer_into!(new_pars, prob.f.sys, prob)
  return new_pars
end

function transfer_into!(pars::MTKParams, model::System, prob::ODEProblem)
  for nm in propertynames(pars)
    if !hasproperty(model, nm)
      @warn "$(ModelingToolkit.get_name(model)) does not contain $nm"
      continue
    end

    sym = getproperty(model, nm)
    if sym isa System
      transfer_into!(getproperty(pars, nm), sym, prob)
    else
      val = try
        prob.ps[sym]
      catch e
        @warn "could not read `$(ModelingToolkit.getname(sym))` from `prob.ps`" exception=e
        continue
      end

      if ismissing(val)
        @warn "`$(ModelingToolkit.getname(sym))` resolved to `missing` in `prob.ps`, keeping previous value"
        continue
      end

      setproperty!(pars, nm, val)
    end
  end
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
