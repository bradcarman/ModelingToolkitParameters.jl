# API Reference

## Parameter Object Generation

```@docs
ModelingToolkitParameters.MTKParams
@mtkparams
```

## Parameter Map Generation

```@docs
ModelingToolkitParameters.pmap
Base.Pair(::ModelingToolkitBase.System, ::MTKParams)
```

## Caching and Updates

```@docs
ModelingToolkitParameters.cache
ModelingToolkitParameters.update!
```

## Serialization

```@docs
ModelingToolkitParameters.save_parameters
ModelingToolkitParameters.load_parameters
ModelingToolkitParameters.parameters_to_string
ModelingToolkitParameters.string_to_parameters
```

## Type Conversions

```julia
Base.Dict(::MTKParams)
Base.setproperty!(::MTKParams, ::Dict)
Base.copy(::MTKParams)
```

# Internals
Use this functions to access the internal properties of a `MTKParams` 

```@docs
get_parent
get_defs
```
