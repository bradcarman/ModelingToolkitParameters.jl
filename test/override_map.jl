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

@component function RCModel(; name)

    pars = @parameters begin
        gain = 10
    end

    vars = @variables begin
        x(t) = 0
    end

    systems = @named begin
        capacitor = Capacitor()
        source = ConstantVoltage()
        pin = Pin()
    end

    initial_conditions = [
        (source => special)...
    ]
    
    eqs = [
            D(x) ~ gain
            connect(source.p, capacitor.p)
            connect(capacitor.n, source.n)
            connect(capacitor.n, pin)
        ]
    return System(eqs, t, vars, pars; name, systems, initial_conditions)
end

RCModelParams = build_params(RCModel)
rc_model_params = RCModelParams(gain = 20)

@component function TopRCModel(; name)
    systems = @named begin
        rc_model = RCModel()
        ground = Ground()
    end

    initial_conditions = [
        (rc_model => rc_model_params)...
    ]
    
    eqs = [
            connect(rc_model.pin, ground.g)
        ]
    return System(eqs, t, [], []; name, systems, initial_conditions)
end


#test case use_resistor = true
@mtkcompile top_rc_model = TopRCModel()
defs = ModelingToolkit.initial_conditions(top_rc_model)


TopRCModelParams = build_params(top_rc_model)
top_rc_model_params = TopRCModelParams()
@test top_rc_model_params.rc_model.source.V == special.V
@test top_rc_model_params.rc_model.gain == rc_model_params.gain

