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

special = ConstantVoltageParams(V=20.0)

@test special.V == 20.0

@named source = ConstantVoltage()
pmap = source => special

@test isequal(pmap, [source.V => 20.0])