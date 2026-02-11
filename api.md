# API Reference

```@index
```

## Parameter Structure Generation

```@docs
params
Params
```

## Parameter Mapping

```@docs
pmap
```

## Caching and Updates

```@docs
cache
update!
```

## Serialization

```@docs
save_parameters
load_parameters
parameters_to_string
string_to_parameters
```

## Type Conversions

```@docs
Base.Pair(::ODESystem, ::Params)
Base.Dict(::Params)
Base.setproperty!(::Params, ::Dict)
Base.copy(::Params)
```
