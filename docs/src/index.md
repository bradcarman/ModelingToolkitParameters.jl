# ModelingToolkitParameters - Introduction and Motivation
Currently the standard way to build parameters up in ModelingToolkit models is with the following pattern of keyword arguments with default values.  

```julia
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using OrdinaryDiffEq

@component function Motor(; name, k = 0.1, r = 0.01, l = 1e-3)
  pars = @parameters begin
    k = k
    r = r
    l = l
  end
  vars = @variables begin
    v(t)
    dphi(t) = 0
    i(t) = 0
    di(t)
  end
  eqs = Equation[
    D(i) ~ di
    v ~ i * r + l * di + dphi * k
    D(dphi) ~ k * i
    v ~ sin(t)
  ]

  return ODESystem(eqs, t, vars, pars; name)
end
```




This patern heavily relies on the `defaults` mechanism of the model to actually set the parameters of the model.  Let say we want `k, r, l` to be `1, 2, 3`.  One way we can do this is

```julia
@mtkcompile sys = Motor(k=1, r=2, l=3)
```

This is simple enough, but what if we want another instance with `k, r, l` to be `4, 5, 6`?  Should we fully rebuild the model? No, this is inefficient.  Instead it's better to set parameters at the ODEProblem level with remake to reuse the already structurally simplified system...

```julia
@mtkcompile sys = Motor() # build system once
prob = ODEProblem(sys, [], (0,1)) # build problem once

prob1 = remake(prob; p = [sys.k => 1, sys.r => 2, sys.l => 3]) # reuse prob, update parameters
prob2 = remake(prob; p = [sys.k => 4, sys.r => 5, sys.l => 6]) # reuse prob, update parameters again
```

Note, now we are __not__ using the keyword arguments of the model constructor now.  Instead we are building the parameter map from scratch.  Therefore, the cons of the keyword model construction pattern are:

 1. makes the model interface more complicated.  As the list of parameters grows, the keyword list becomes un-manageable
 2. it's essentially useless if more than one model instance is needed
 3. building a parameter map for `remake` still needs to be done from scratch.  (We could get the `defaults` dictionary of the model, but we still need to index into each parameter with `sys.k`, `sys.r`, etc.)

The additional problems with this pattern are:

 4. there are no ways to enforce parameter settings rules with useful error messages, for example ensuring postive numbers 
 5. parameter maps are not easy to work with since they are flat
 6. parameter maps are not printed with heirarcy and are therefore not easily saved/retrieved to/from file using TOML or JSON

# A Better Way
ModelingToolkitParameters.jl provides a type `MTKParams` that creates a parameter object that is much easier to work with.  The `Motor` component can now be defined as follows with no keyword arguments.  Then we can generate a `MTKParams` object to hold parameter values.

```julia 
using ModelingToolkitParameters

@component function Motor(; name)
  pars = @parameters begin
    k = 0.1
    r = 0.01
    l = 1e-3
  end
  vars = @variables begin
    v(t)
    dphi(t) = 0
    i(t) = 0
    di(t)
  end
  eqs = Equation[
    D(i) ~ di
    v ~ i * r + l * di + dphi * k
    D(dphi) ~ k * i
    v ~ sin(t)
  ]

  return ODESystem(eqs, t, vars, pars; name)
end

@mtkparams motor_pars = Motor()
```
Which gives...

```julia
Motor
├─ k: 0.1
├─ r: 0.01
└─ l: 0.001
```

!!! note "keyword args"
    Note we can also enter keyword arguments here to override defaults.  Additionally, as will be shown in the next section, this can be done for child components as well.

    ```julia
    julia> @mtkparams motor_pars = Motor(k=12, r=23, l=34)
    Motor
    ├─ k: 12
    ├─ r: 23
    └─ l: 34
    ```

A parameter map used for building `ODEProblem` can be generated from `pmap(sys::ModelingToolkit.System, p::MotorParams)`, for example

```julia
@mtkcompile sys = Motor()

motor_pars.k=1
motor_pars.r=2
motor_pars.l=3

ps = pmap(sys, motor_pars)
```

Gives...

```julia
3-element Vector{Pair}:
 k => 1.0
 r => 2.0
 l => 3.0
```

Now we can easily modify parameters using the Julia parameter object `motor_pars`.  Like

```julia
prob = ODEProblem(sys, ps, (0, 0.1))

motor_pars2 = copy(motor_pars)
motor_pars2.k = 4.0

prob2 = remake(prob; p = pmap(sys, motor_pars2))
```

Now that our parameters are given by an object, we have many additional benefits:
- better display of parameters in tree form
- parameter bounds are applied
- save/load from file easily
- copy, mutate, and remake (including with a fast cache method shown below)


## Model Heirarchy and Catalogs
Let's explore a heirarchal model and how we can build and apply a catalog.  We will build a `MassSpringDamper` component that has the child systems `Mass`, `Spring`, and `Damper`. The Active Suspension model seen in the examples defines the simple mass, spring, damper components all with no defaults and no keyword constructors.

Now, we can build a composite component MassSpringDamper

```julia
@component function MassSpringDamper(;name)

    systems = @named begin
        damper = Damper()
        body = Mass()
        spring = Spring()
        port_m = MechanicalPort()
        port_sd = MechanicalPort()        
    end

    eqs = [       
        connect(damper.flange_a, spring.flange_a, body.flange, port_m)
        connect(port_sd, spring.flange_b, damper.flange_b)
    ]

    return System(eqs, t, [], []; systems, name)
end
```

This model will require several `MassSpringDampers` representing the wheels, car, and seat.  We can build a Catalog of these components easily using the `@mtkparams` macro like

```julia
@mtkparams seat_pars  = MassSpringDamper(body=Mass(m=100),  spring=Spring(k=1000), damper=Damper(d=1))
@mtkparams car_pars   = MassSpringDamper(body=Mass(m=1000), spring=Spring(k=1e4),  damper=Damper(d=10))
@mtkparams wheel_pars = MassSpringDamper(body=Mass(m=25),   spring=Spring(k=1e2),  damper=Damper(d=1e4))
```

Now when we build the top level model we can set the component initial_conditions to the catalog items as follows...

```julia
@component function Model(; name)

    systems = @named begin
        seat = MassSpringDamper()
        car_and_suspension = MassSpringDamper()
        wheel = MassSpringDamper()
        road_data = Road()
        road = Position()
        force = Force()
        pid = Controller()
        err = Subtract() 
        set_point = Constant()
        seat_pos = PositionSensor()
        flip = Gain(k=-1)
    end

    initial_conditions = [
        (seat => seat_pars)...
        (car_and_suspension => car_pars)...
        (wheel => wheel_pars)...
    ]

    . . .

    return System(eqs, t, [], pars; systems, name, initialization_eqs, initial_conditions)
end
```

Now we can build a parameter object of `Model` as follows and see that the catalog of `MassSpringDamper` parameters was implemented...

```julia
julia> sys_pars = MTKParams(ActiveSuspensionModel.Model)
Model
├─ g: -9.807
├─ seat
│  ├─ damper
│  │  └─ d: 1.0
│  ├─ body
│  │  └─ m: 100.0
│  └─ spring
│     ├─ k: 1000.0
│     └─ initial_stretch: missing
├─ car_and_suspension
│  ├─ damper
│  │  └─ d: 10.0
│  ├─ body
│  │  └─ m: 1000.0
│  └─ spring
│     ├─ k: 10000.0
│     └─ initial_stretch: missing
├─ wheel
│  ├─ damper
│  │  └─ d: 10000.0
│  ├─ body
│  │  └─ m: 25.0
│  └─ spring
│     ├─ k: 100.0
│     └─ initial_stretch: missing
├─ road_data
│  ├─ bump: 0.2
│  ├─ freq: 0.5
│  ├─ offset: 1.0
│  └─ loop: 10
├─ pid
│  ├─ kp: 1.0
│  ├─ ki: 0.2
│  └─ kd: 20.0
├─ err
│  ├─ k1: 1.0
│  └─ k2: -1
├─ set_point
│  └─ k: 0
└─ flip
   └─ k: -1
```


# Speed
As mentioned previously, using the keyword default patern for model parameter setting is not a good way to build several model variations, as this requires fully compiling/simplifying the model from scratch each time.  A better way was shown with ModelingToolkitParameters.jl using `remake` and proving an updated parameter map.  However, this way is still not the fastest.  The most efficient approach is to use `SymbolicIndexingInterface.jl`.  `ModelingToolkitParameters.jl` provides a `cache` function that implements the `SymbolicIndexingInterface.jl` utility to provide a more efficient use of `remake`.  The example below demonstrates this comparison.


```@example speed
using ModelingToolkit
using ModelingToolkitParameters
using ActiveSuspensionModel
using SciMLBase
using BenchmarkTools

@mtkcompile model = ActiveSuspensionModel.Model()
@mtkparams model_pars = ActiveSuspensionModel.Model()
prob = ODEProblem(model, pmap(model, model_pars), (0, 10))

# Slow Option
model_pars.seat.body.m = 200                                                # change parameters
prob2 = remake(prob; p = pmap(model, model_pars))                           # remake ODEProblem
time_slow = @belapsed prob2 = remake($prob; p = pmap($model, $model_pars))  # remake ODEProblem (timed)

# Fast Option
model_setters = cache(model, model_pars);# build cache (one time only)

model_pars.seat.body.m = 300                                                            # change parameters
prob3 = remake(prob, model_setters, pmap(model, model_pars))                            # fast remake ODEProblem
time_fast = @belapsed prob3 = remake($prob, $model_setters, pmap($model, $model_pars))  # fast remake ODEProblem (timed)

@show time_slow time_fast # hide
nothing # hide
```


# Saving and Loading Parameters
The advantage of storing parameters into structs is that they can now be easily saved and loaded from text file.  The code below will demonstrate how to use the TOML format to create parameter files.  The TOML library in Julia can easily write out code if the data is in a dictionary.  We can easily convert our parameter structs to dictionary.

```@example speed
Dict(model_pars)
```

Saving with TOML format (which can easily print from a `Dict`) can be done using

```julia
save_parameters(model_pars, "model_pars.toml")
```

This will save out a file that looks like...

```@example speed
using TOML
TOML.print(ModelingToolkitParameters.convert_value, Dict(model_pars))
```

_Note: `convert_value` can be used to help with saving complex types.  See TOML documentation for more information._


Then loading from file is done with `load_parameters(filepath::String, T::Type)` where `T` is the matching parameter struct type...

```julia; results="hidden"
model_pars = load_parameters("model_pars.toml", ActiveSuspensionModel.Model) 
```

From text, this works like the following

```@example speed
@mtkparams p = ActiveSuspensionModel.Road()
setproperty!(p, TOML.parse("""
                          bump = 0.3
                          freq = 0.75
                          offset = 3
                          """))
Dict(p)
```

# Structural Parameters
In some cases we might have a model that uses structural parameters, ones that change the system itself.  For example the model below has a structural parameter `use_resistor` which changes the model structurally, by either including or not including a resistor in the circuit.  

```julia
@component function RCModel(use_resistor=true; name)
    systems = @named begin
        capacitor = Capacitor()
        source = ConstantVoltage()
        ground = Ground()
    end

    initial_conditions = [
        (source => special)...
    ]

    if use_resistor
        @named resistor = Resistor()
        push!(systems, resistor)
    end
    
    eqs = if use_resistor
        [
            connect(source.p, resistor.p)
            connect(resistor.n, capacitor.p)
            connect(capacitor.n, source.n)
            connect(capacitor.n, ground.g)
        ]
    else
        [
            connect(source.p, capacitor.p)
            connect(capacitor.n, source.n)
            connect(capacitor.n, ground.g)
        ]
    end
    return System(eqs, t, [], []; name, systems, initial_conditions)
end
```

For a model like this, we can't simply use the form `@mtkparams rcmodel_res_pars = RCModel()` or `rcmodel_res_pars = MTKParams(RCModel)`, because `RCModel` could have 2 different sets of parameters based on the build time structural parameter.  Instead, what we can do is build the parameter object from model instances, post build time, like...

```@example rc_model
include("../../test/model.jl") # hide
@named rc_model_res = RCModel(true)
rc_model_res_pars = MTKParams(rc_model_res)
```

And then without the resistor

```@example rc_model
@named rc_model_nor = RCModel(false)
rc_model_nor_pars = MTKParams(rc_model_nor)
```

!!! note "load_parameters"
    The same concept applies to `load_parameters`.  The 2nd argument can be either:
    - a model constructor function
    - an instantiated model `System`
    - a `MTKParams` parameter object

!!! warning "avoid simplified system"
    `MTKParams` accepts only a non-structurally simplified `System` (i.e. use `@named` and not `@mtkcompile` ).  This is necessary so the sub-systems information is available, as structurally simplified systems are flattened.  

