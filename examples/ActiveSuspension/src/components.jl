
# Model Parts -------------------------------------------
@connector function RealInput(;name)
    @variables u(t) [input=true]
    return System(Equation[], t, [u], []; name)
end

@connector function RealOutput(;name)
    @variables u(t) [output=true]
    return System(Equation[], t, [u], []; name)
end

@connector function MechanicalPort(;name)
    @variables begin
        x(t)
        f(t), [connect = Flow]
    end

    return System(Equation[], t, [x, f], []; name)
end


# -------------------------------------------------------------------
const g = -9.807

# @component function Globals(; name)
#   @parameters begin
#     g=g
#   end

#   g = GlobalScope(g)

#   return System(Equation[], t, [], [g]; name)
# end

@component function Add(; name)
    pars = @parameters begin
        k1=1.0
        k2=1.0
    end
    systems = @named begin
        input1 = RealInput()
        input2 = RealInput()
        output = RealOutput()
    end
    eqs = [
        output.u ~ k1 * input1.u + k2 * input2.u
    ]
    return System(eqs, t, [], pars; name, systems)
end

@component function Subtract(; name)
    @named add = Add()
    @unpack k2 = add
    initial_conditions=[k2=>-1]
    return extend(System(Equation[], t, [], []; initial_conditions, name), add)
end

const add_pars = MTKParams(Add; k1=1, k2=1)
const subtract_pars = MTKParams(Add; k1=1, k2=-1)

@component function Constant(; name)
    pars = @parameters begin
        k=0
    end
    systems = @named begin
        output = RealOutput()
    end
    eqs = [
        output.u ~ k
    ]
    return System(eqs, t, [], pars; name, systems)
end


@component function Gain(; name, k=1.0)
    pars = @parameters begin
        k=k
    end
    systems = @named begin
        input = RealInput()
        output = RealOutput()
    end
    eqs = [
        output.u ~ k * input.u
    ]
    return System(eqs, t, [], pars; name, systems)
end

@component function Force(; name)
    systems = @named begin
        flange_a = MechanicalPort()
        flange_b = MechanicalPort()
        f = RealInput()
    end
    eqs = [
        flange_a.f ~ +f.u
        flange_b.f ~ -f.u
    ]
    return System(eqs, t, [], []; name, systems)
end


@component function Position(;name)
    systems = @named begin
        flange = MechanicalPort()
        s = RealInput()
    end
    eqs = [
        flange.x ~ s.u
    ]
    return System(eqs, t, [], []; name, systems)
end


@component function PositionSensor(;name)
    systems = @named begin
        flange = MechanicalPort()
        output = RealOutput()
    end
    eqs = [
        output.u ~ flange.x
        flange.f ~ 0.0
    ]
    return System(eqs, t, [], []; name, systems)
end

@component function PositionInput(;name)
    systems = @named begin
        flange = MechanicalPort()
        input = RealInput()
    end
    eqs = [
        input.u ~ flange.x
        flange.f ~ 0.0
    ]
    return System(eqs, t, [], []; name, systems)
end

@component function Unknown(; name)
    vars = @variables begin
        x(t)
    end
    systems = @named begin
        output = RealOutput()
    end
    eqs = [
        output.u ~ x
    ]
    return System(eqs, t, vars, []; name, systems)
end


@component function Mass(; name)
    pars = @parameters begin
        m, [bounds=(0.0, NaN)]
    end
    vars = @variables begin
        s(t)
        v(t)
        f(t)
        a(t)
    end
    systems = @named begin
        flange = MechanicalPort()
    end 

    @parameters g
    g = GlobalScope(g)
    
    eqs = [
        s ~ flange.x
        f ~ flange.f

        D(s) ~ v
        D(v) ~ a
        m*a ~ f + m*g
    ]
    return System(eqs, t, vars, pars; name, systems)
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

# ----------------------------------