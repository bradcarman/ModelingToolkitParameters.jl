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


@component function Resistor(;name)
    systems = @named begin
        p = Pin()
        n = Pin()
    end
    pars = @parameters begin
        R=1.0, [bounds=(0, Inf)]
    end
    eqs = [
        p.v - n.v ~ p.i * R
        0 ~ p.i + n.i
    ]        
    return System(eqs, t, [], pars; name, systems)
end


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


@component function ConstantVoltage(;name)
    systems = @named begin
        p = Pin()
        n = Pin()
    end
    pars = @parameters begin
        V = 10.0
        initial_voltage = missing, [guess=0]
    end
    eqs = [
        V ~ p.v - n.v + initial_voltage
        0 ~ p.i + n.i
    ]        
    return System(eqs, t, [], pars; name, systems)
end

special = MTKParams(ConstantVoltage; V = 20)

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
@named rc_model1 = RCModel(true)
defs = ModelingToolkit.initial_conditions(rc_model1)


rc_model1_params = MTKParams(rc_model1);
@test rc_model1_params.source.V == special.V
@test_throws ErrorException  rc_model1_params.resistor.R = -1
@test rc_model1_params.resistor.R == 1.0


@named rc_model2 = RCModel(false)
defs = ModelingToolkit.initial_conditions(rc_model1)

rc_model2_params = MTKParams(rc_model2)
@test rc_model2_params.source.V == special.V

rc_model1 => rc_model1_params
rc_model2 => rc_model2_params


rc_model1 => rc_model2_params
rc_model2 => rc_model1_params


cap = rc_model1_params.capacitor
cap.C = 2.0

rc_model2_params.capacitor = cap

@test rc_model2_params.capacitor.C == 2.0


rc_model3_params = MTKParams(RCModel; capacitor=MTKParams(Capacitor; C=3.0))

rc_model1 => rc_model3_params


sys = mtkcompile(rc_model1)
@test_throws AssertionError MTKParams(sys)