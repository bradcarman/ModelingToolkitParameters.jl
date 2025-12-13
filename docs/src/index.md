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
@mtkbuild sys = Motor(k=1, r=2, l=3)
```

This is simple enough, but what if we want another instance with `k, r, l` to be `4, 5, 6`?  Should we fully rebuild the model?  Instead it's better to set parameters at the ODEProblem level...

```julia
@mtkbuild sys = Motor()
prob = ODEProblem(sys, [], (0,1))

prob1 = remake(prob; p = [sys.k => 1, sys.r => 2, sys.l => 3])
prob2 = remake(prob; p = [sys.k => 4, sys.r => 5, sys.l => 6])
```

Note, now we are __not__ using the keyword arguments of the model constructor.  Instead we are building the parameter map from scratch.  Therefore, the cons of the keyword model construction pattern are:

 1. makes the model interface more complicated.  As the list of parameters grows, the keyword list becomes un-manageable
 2. it's essentially useless if more than one model instance is needed
 3. building a parameter map for `remake` still needs to be done from scratch.  (We could get the `defaults` dictionary of the model, but we still need to index into each parameter with `sys.k`, `sys.r`, etc.)

The additional problems with this pattern are:

 4. there are no ways to enforce parameter settings rules with useful error messages, for example ensuring postive numbers 
 5. parameter maps are not easy to work with since they are flat
 6. parameter maps are not printed with heirarcy and are therefore not easily saved/retrieved to/from file using TOML or JSON

# A Better Way
ModelingToolkitParameters.jl exports an abstract type `Params` that can be used to build parameter maps using Julia structs.  The `Motor` component can now be defined as follows where a mutable Julia struct `MotorParams` is defined with the same names as the `Motor` component parameters.

```julia 
using ModelingToolkitParameters
@kwdef mutable struct MotorParams <: Params
    k::Float64 = 0.1
    r::Float64 = 0.01
    l::Float64 = 1e-3
end

@component function Motor(; name)
  pars = @parameters begin
    k 
    r
    l
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

Now we can build the parameter map by asking for the pair (=>):  `sys::ModelingToolkit.System => p::MotorParams`, for example

```julia
@mtkbuild sys = Motor()
motor_pars = MotorParams(k=1,r=2,l=3)

pmap = sys => motor_pars
```

Gives...
```
3-element Vector{Pair}:
 k => 1.0
 r => 2.0
 l => 3.0
```

Now we can easily modify parameters using the Julia parameter struct `motor_pars`.  Like

```julia
prob = ODEProblem(sys, pmap, (0.1))

motor_pars2 = copy(motor_pars)
motor_pars2.k = 4.0

prob2 = remake(prob; p = sys => motor_pars2)
```

Now that our parameters are generated from a Julia struct we have many additional benefits, we can:
- use `getproperty` to set rules
- define `print` rules (and save/load from file easily)
- define `copy` 
- define constructors

## Model Heirarchy and Catalogs
As we move into heirarcal models, we can continue the patern of defining a `struct` that maps to the component, however we now add the parameters and the child systems.  We will build a `MassSpringDamper` component that has the child systems `Mass`, `Spring`, and `Damper`. The Active Suspension model seen here [https://github.com/bradcarman/ActiveSuspensionModel/tree/main/ActiveSuspensionModel.jl](https://github.com/bradcarman/ActiveSuspensionModel/tree/main/ActiveSuspensionModel.jl) defines the simple mass, spring, damper components like

```julia
Base.@kwdef mutable struct MassParams <: Params
    m::Real
end

@component function Mass(; name)
    pars = @parameters begin
        m
    end
    vars = @variables begin
        s(t)
        v(t)
        f(t)
        a(t)
    end
    systems = @named begin
        globals = Globals()
        flange = MechanicalPort()
    end 

    @unpack g = globals
    
    eqs = [
        s ~ flange.x
        f ~ flange.f

        D(s) ~ v
        D(v) ~ a
        m*a ~ f + m*g
    ]
    return System(eqs, t, vars, pars; name, systems)
end

# ------------------------------------------------

Base.@kwdef mutable struct SpringParams <: Params
    k::Real
end

@component function Spring(; name)
    pars = @parameters begin
        k
        initial_stretch=missing, [guess=0]
    end
    vars = @variables begin
        delta_s(t)
        f(t)
    end
    systems = @named begin
        flange_a = MechanicalPort()
        flange_b = MechanicalPort()
    end 
    eqs = [
        delta_s ~ (flange_a.x - flange_b.x) + initial_stretch
        f ~ k * delta_s
        flange_a.f ~ +f
        flange_b.f ~ -f
    ]
    return System(eqs, t, vars, pars; name, systems)
end

# ------------------------------------------------

Base.@kwdef mutable struct DamperParams <: Params
    d::Real
end

@component function Damper(; name)
    pars = @parameters begin
        d
    end
    vars = @variables begin
        delta_s(t), [guess=0]
        f(t), [guess=0]
    end
    systems = @named begin
        flange_a = MechanicalPort()
        flange_b = MechanicalPort()
    end 
    eqs = [
        delta_s ~ flange_a.x - flange_b.x
        f ~ D(delta_s) * d
        flange_a.f ~ +f
        flange_b.f ~ -f
    ]
    return System(eqs, t, vars, pars; name, systems)
end
```

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

This component's parameter struct is then comprised of matching names of the child systems

```julia
Base.@kwdef mutable struct MassSpringDamperParams <: Params
    # systems
    damper::DamperParams = DamperParams()
    body::MassParams = MassParams()
    spring::SpringParams = SpringParams()
end
```

This model will require several `MassSpringDampers` representing the wheels, the car and suspension, and the seat and passanger.  We can build a Catalog of these components easily like

```julia
const seat = MassSpringDamperParams(;body=MassParams(m=100), spring=SpringParams(k=1000), damper=DamperParams(d=1))
const car = MassSpringDamperParams(;body=MassParams(m=1000), spring=SpringParams(k=1e4), damper=DamperParams(d=10))
const wheel = MassSpringDamperParams(;body=MassParams(m=25), spring=SpringParams(k=1e2), damper=DamperParams(d=1e4))
```

Now when we build the top level model

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
        err = Add() 
        set_point = Constant()
        seat_pos = PositionSensor()
        flip = Gain()
    end

    eqs = [
        
        # mechanical model
        connect(road.s, road_data.output)
        connect(road.flange, wheel.port_sd)
        connect(wheel.port_m, car_and_suspension.port_sd)
        connect(car_and_suspension.port_m, seat.port_sd, force.flange_a)
        connect(seat.port_m, force.flange_b, seat_pos.flange)
        
        # controller        
        connect(err.input1, seat_pos.output)
        connect(err.input2, set_point.output)
        connect(pid.err_input, err.output)
        connect(pid.ctr_output, flip.input)
        connect(flip.output, force.f)        
    ]

    return System(eqs, t, [], []; systems, name)
end
```

The parameter struct can be easily created from this catalog

```julia
Base.@kwdef mutable struct ModelParams <: Params
    # parameters
    g::Real = g
    # systems
    seat::MassSpringDamperParams = seat
    car_and_suspension::MassSpringDamperParams = car
    wheel::MassSpringDamperParams = wheel
    road_data::RoadParams = RoadParams()
    pid::ControllerParams = ControllerParams()
    err::AddParams = subtract
    set_point::ConstantParams = ConstantParams()
    flip::GainParams = GainParams(k=-1)
end
```

# Speed
As mentioned previously, using the keyword default patern for model parameter setting is not a good way to build several model variations, as this requires fully compiling/simplifying the model from scratch each time.  A better way was shown with ModelingToolkitParameters.jl using `remake` and proving an updated parameter map.  However, this way is still not the fastest.  The most efficient approach is to use `SymbolicIndexingInterface.jl`.  


```@example 
using ModelingToolkit
using ModelingToolkitParameters
using ActiveSuspensionModel
using SciMLBase
using BenchmarkTools

@mtkcompile model = ActiveSuspensionModel.Model()
model_pars = ActiveSuspensionModel.ModelParams()
prob = ODEProblem(model, model=>model_pars, (0, 10))

# Slow Option
model_pars.seat.body.m = 200                                    # change parameters
@btime prob2 = remake(prob; p = model => model_pars);           # remake ODEProblem

# Fast Option
model_setters = cache(model, ActiveSuspensionModel.ModelParams);# build cache (one time only)

model_pars.seat.body.m = 300                                    # change parameters
@btime prob3 = remake(prob, model_setters, model => model_pars);# remake ODEProblem
```