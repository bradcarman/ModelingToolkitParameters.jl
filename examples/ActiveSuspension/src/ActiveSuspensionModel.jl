module ActiveSuspensionModel
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using RuntimeGeneratedFunctions
using PrecompileTools
using ModelingToolkitParameters
RuntimeGeneratedFunctions.init(@__MODULE__)

# base model components
include("components.jl")

# top level model 
# -----------------------------------------------------

#y data as a function of time (assuming car is traveling at constant speed of 15m/s)
@component function Road(; name)
    
    systems = @named begin
        output = RealOutput()
    end
    
    pars = @parameters begin
        bump = 0.2
        freq = 0.5
        offset = 1.0
        loop = 10
    end

    𝕓 = bump*(1 - cos(2π*(t-offset)/freq))
    τ = mod(t, loop)

    eqs = [
        output.u ~ ifelse( τ < offset, 
            0.0, 
                ifelse( τ - offset > freq, 
                    0.0, 
                        𝕓)
        )
    ]

    return ODESystem(eqs, t, [], pars; name, systems)
end


@component function Controller(; name)
    
    pars = @parameters begin
        kp = 1.0
        ki = 0.2
        kd = 20.0
    end

    vars = @variables begin
        x(t)
        dx(t)
        ddx(t)
        y(t)
        dy(t)
    end
    
    systems = @named begin
        err_input = RealInput()
        ctr_output = RealOutput()
    end


    # equations ---------------------------
    eqs = [

        D(x) ~ dx
        D(dx) ~ ddx
        D(y) ~ dy
        

        err_input.u ~ x
        ctr_output.u ~ y 

        dy ~ kp*(dx + ki*x + kd*ddx)

    ]

    return ODESystem(eqs, t, vars, pars; systems, name)
end


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

MassSpringDamperParams = build_params(MassSpringDamper; eval_module=@__MODULE__)

const seat_pars = MassSpringDamperParams(;body=MassParams(m=100), spring=SpringParams(k=1000), damper=DamperParams(d=1))
const car_pars = MassSpringDamperParams(;body=MassParams(m=1000), spring=SpringParams(k=1e4), damper=DamperParams(d=10))
const wheel_pars = MassSpringDamperParams(;body=MassParams(m=25), spring=SpringParams(k=1e2), damper=DamperParams(d=1e4))


# Base.@kwdef mutable struct ModelParams <: Params
#     # parameters
#     g::Real = g
#     # systems
#     seat::MassSpringDamperParams = seat
#     car_and_suspension::MassSpringDamperParams = car
#     wheel::MassSpringDamperParams = wheel
#     road_data::RoadParams = RoadParams()
#     pid::ControllerParams = ControllerParams()
#     err::AddParams = subtract
#     set_point::ConstantParams = ConstantParams()
#     flip::GainParams = GainParams(k=-1)
# end


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

    initial_conditions = [
        (seat => seat_pars)...
        (car_and_suspension => car_pars)...
        (wheel => wheel_pars)...
        (err => subtract)...
        (flip => flip_pars)...
    ]

    
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


    initialization_eqs = [
        wheel.body.s ~ 0.5
        car_and_suspension.body.s ~ 1.0
        seat.body.s ~ 1.5

        wheel.body.v ~ 0
        car_and_suspension.body.v ~ 0
        seat.body.v ~ 0

        wheel.body.a ~ 0
        car_and_suspension.body.a ~ 0
        seat.body.a ~ 0

        force.f.u ~ 0
    ]

    return System(eqs, t, [], []; systems, name, initialization_eqs, initial_conditions)
end


# Base.@kwdef mutable struct InverseModelParams <: Params
#     # parameters
#     g::Real = g
#     # systems
#     seat::MassSpringDamperParams = seat
#     car_and_suspension::MassSpringDamperParams = car
#     wheel::MassSpringDamperParams = wheel
#     road_data::RoadParams = RoadParams()
#     set_point::ConstantParams = ConstantParams()
#     flip::GainParams = GainParams()
# end

# @component function InverseModel(; name)

#     systems = @named begin
#         seat = MassSpringDamper()
#         car_and_suspension = MassSpringDamper()
#         wheel = MassSpringDamper()
#         road_data = Road()
#         road = Position()
#         force = Force()
#         set_point = Constant()
#         seat_pos = PositionInput()
#         flip = Gain()

#         unknown = Unknown()
#     end

#     eqs = [
        
#         # mechanical model
#         connect(road.s, road_data.output)
#         connect(road.flange, wheel.port_sd)
#         connect(wheel.port_m, car_and_suspension.port_sd)
#         connect(car_and_suspension.port_m, seat.port_sd, force.flange_a)
#         connect(seat.port_m, force.flange_b, seat_pos.flange)
        
#         # controller        
#         connect(set_point.output, seat_pos.input)
#         connect(unknown.output, flip.input)
#         connect(flip.output, force.f)        
#     ]

#     initialization_eqs = [
#         wheel.body.s ~ 0.5
#         car_and_suspension.body.s ~ 1.0
#         # seat.body.s ~ 1.5

#         wheel.body.v ~ 0
#         car_and_suspension.body.v ~ 0
#         # seat.body.v ~ 0

#         wheel.body.a ~ 0
#         car_and_suspension.body.a ~ 0
#         # seat.body.a ~ 0

#         force.f.u ~ 0
#     ]

#     return System(eqs, t, [], []; systems, name, initialization_eqs)
# end




# API -----------------
# @mtkbuild sys = System()
# initialization_eqs = [

#     sys.seat.body.s ~ 1.5
#     sys.seat.body.v ~ 0.0
#     sys.seat.body.a ~ 0.0

#     sys.car_and_suspension.body.s ~ 1.0
#     sys.car_and_suspension.body.v ~ 0.0
#     sys.car_and_suspension.body.a ~ 0.0

#     sys.wheel.body.s ~ 0.5
#     sys.wheel.body.v ~ 0.0
#     sys.wheel.body.a ~ 0.0

#     sys.pid.y ~ 0.0
# ]

# prob = ODEProblem(sys, [], (0, 10); eval_expression = false, eval_module = @__MODULE__, initialization_eqs)


end # module ActiveSuspensionModel





