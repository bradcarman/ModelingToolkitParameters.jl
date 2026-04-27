using ModelingToolkit
using ModelingToolkit: D_nounits as D, t_nounits as t
using ModelingToolkitParameters
using Test

@connector function Pin(;name)
    vars = @variables begin
        v(t)
        i(t), [connect = Flow]    
    end

    @parameters g
    g = GlobalScope(g)
    
    return System(Equation[], t, vars, [g]; name)
end

@component function ConstantVoltage(;name)
    systems = @named begin
        p = Pin()
        n = Pin()
    end
    @unpack g = p
    pars = @parameters begin
        V = 10.0
        initial_stretch=missing, [guess=0]
    end
    eqs = [
        V ~ p.v - n.v + g + initial_stretch
        0 ~ p.i + n.i
    ]        
    return System(eqs, t, [], pars; name, systems)
end

@named v = ConstantVoltage()
ps = ModelingToolkit.get_ps(v)
ModelingToolkit.initial_conditions(v)




pars = ModelParams(v)

pars.V
pars.V = 20.0

pars

Symbolics.symtype(ps[2])

ConstantVoltageParams = build_params(ConstantVoltage)

special = ConstantVoltageParams(V=20.0, initial_stretch=missing)

@test special.V == 20.0

@named source = ConstantVoltage()
pmap = source => special

@test isequal(pmap, [source.V => 20.0])

