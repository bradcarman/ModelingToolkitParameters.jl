using Test
using ModelingToolkit
using ModelingToolkit: D_nounits as D, t_nounits as t
using ModelingToolkitParameters

@connector Pin begin
    v(t)
    i(t), [connect = Flow]
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


Base.@kwdef mutable struct ResistorParams <: Params
    R::Real = 1.0
end

@component function Resistor(;name)
    systems = @named begin
        p = Pin()
        n = Pin()
    end
    pars = @parameters begin
        R
    end
    eqs = [
        p.v - n.v ~ p.i * R
        0 ~ p.i + n.i
    ]        
    return System(eqs, t, [], pars; name, systems)
end


Base.@kwdef mutable struct CapacitorParams <: Params
    C::Real = 0.1
end

@component function Capacitor(;name)
    systems = @named begin
        p = Pin()
        n = Pin()
    end
    pars = @parameters begin
        C
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


Base.@kwdef mutable struct ConstantVoltageParams <: Params
    V::Real = 10.0
end

@component function ConstantVoltage(;name)
    systems = @named begin
        p = Pin()
        n = Pin()
    end
    pars = @parameters begin
        V
    end
    eqs = [
        V ~ p.v - n.v
        0 ~ p.i + n.i
    ]        
    return System(eqs, t, [], pars; name, systems)
end



@kwdef mutable struct RCModelParams <: Params
    resistor::ResistorParams = ResistorParams()
    capacitor::CapacitorParams = CapacitorParams()
    source::ConstantVoltageParams = ConstantVoltageParams()
end

@component function RCModel(; name)
    systems = @named begin
        resistor = Resistor()
        capacitor = Capacitor()
        source = ConstantVoltage()
        ground = Ground()
    end
    eqs = [
        connect(source.p, resistor.p)
        connect(resistor.n, capacitor.p)
        connect(capacitor.n, source.n)
        connect(capacitor.n, ground.g)
    ]
    return System(eqs, t, [], []; name, systems)
end

@mtkcompile rc_model = RCModel()
rc_model_params = RCModelParams()
prob = ODEProblem(rc_model, rc_model => rc_model_params, (0, 10.0))


setters = cache(rc_model, RCModelParams)
rc_model_params.resistor.R = 2.0
update!(prob, setters, rc_model => rc_model_params)

@test prob.ps[rc_model.resistor.R] == 2.0

ModelingToolkitParameters.params(RCModel)
