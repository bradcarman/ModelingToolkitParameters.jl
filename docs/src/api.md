# API Reference

## Parameter Structure Generation

```@docs
ModelingToolkitParameters.ModelParams
```

## Parameter Map Generation

```@docs
ModelingToolkitParameters.pmap
Base.Pair(::ModelingToolkitBase.System, ::Params)
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
Base.Dict(::ModelParams)
Base.setproperty!(::ModelParams, ::Dict)
Base.copy(::ModelParams)
```
