# API Reference

## Parameter Structure Generation

```@docs
ModelingToolkitParameters.Params
ModelingToolkitParameters.params
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
ase.Dict(::Params)
Base.setproperty!(::Params, ::Dict)
Base.copy(::Params)
```
