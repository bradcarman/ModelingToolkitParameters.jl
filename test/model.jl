using ModelingToolkit
using ModelingToolkit: D_nounits as D, t_nounits as t
using ModelingToolkitParameters
using Test

@connector function Pin(;name)
    vars = @variables begin
        v(t)
        i(t), [connect = Flow]    
    end
    
    return System(Equation[], t, vars, []; name)
end

@component function Ground(; name)
    systems = @named begin
        g = Pin()
    end
    eqs = [
        g.v ~ 0
    ]
    return System(eqs, t, [], []; name, systems)
end


# Base.@kwdef mutable struct ResistorParams <: Params
#     R::Real = 1.0
# end

@component function Resistor(;name)
    systems = @named begin
        p = Pin()
        n = Pin()
    end
    pars = @parameters begin
        R=1.0
    end
    eqs = [
        p.v - n.v ~ p.i * R
        0 ~ p.i + n.i
    ]        
    return System(eqs, t, [], pars; name, systems)
end


# Base.@kwdef mutable struct CapacitorParams <: Params
#     C::Real = 0.1
# end

@component function Capacitor(;name)
    systems = @named begin
        p = Pin()
        n = Pin()
    end
    pars = @parameters begin
        C=0.1
    end
    vars = @variables begin
        v(t)=0
    end
    eqs = [
        D(v) ~ p.i / C
        v ~ p.v - n.v
        0 ~ p.i + n.i
    ]
    return System(eqs, t, vars, pars; name, systems)
end


# Base.@kwdef mutable struct ConstantVoltageParams <: Params
#     V::Real = 10.0
# end

@component function ConstantVoltage(;name)
    systems = @named begin
        p = Pin()
        n = Pin()
    end
    pars = @parameters begin
        V = 10.0
    end
    eqs = [
        V ~ p.v - n.v
        0 ~ p.i + n.i
    ]        
    return System(eqs, t, [], pars; name, systems)
end

ConstantVoltageParams = build_params(ConstantVoltage)
special = ConstantVoltageParams(V=20)

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


#test case use_resistor = true
@mtkcompile rc_model1 = RCModel(true)
defs = ModelingToolkit.initial_conditions(rc_model1)


RCModel1Params = build_params(rc_model1)
rc_model1_params = RCModel1Params()
@test rc_model1_params.source.V == special.V