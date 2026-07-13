using ActiveSuspensionModel
using ModelingToolkit
using OrdinaryDiffEq
using ModelingToolkitParameters
using WGLMakie

@mtkcompile sys = ActiveSuspensionModel.Model()
prob = ODEProblem(sys, [], (0, 10))
sol = solve(prob; dtmax=0.1)
idxs = [sys.road.s.u, sys.seat.body.s, sys.car_and_suspension.body.s, sys.wheel.body.s]
lines(sol; idxs)

# Start with different Defaults
@mtkcompile sys = ActiveSuspensionModel.Model()
@mtkparams pars = ActiveSuspensionModel.Model(pid=ActiveSuspensionModel.Controller(kp=100))
prob = ODEProblem(sys, pmap(sys, pars), (0, 10))
sol = solve(prob; dtmax=0.1)
lines(sol; idxs)

# Change Parameters using `pars` parameter object
pars.pid.kd = 200.0
prob′ = remake(prob; p = pmap(sys, pars))
sol = solve(prob′; dtmax=0.1)
lines(sol; idxs)

# Change Parameters (fast)
sys_cache = cache(sys, pars)

pars.pid.kd = 2000.0
prob′′ = remake(prob, sys_cache, pmap(sys, pars))  

sol = solve(prob′′; dtmax=0.1)

lines(sol; idxs)


# Implement StructEditor extension

using StructEditor

StructEditor.skip_field(::Type{MTKParams}, ::Val{:g}) = true
StructEditor.skip_field(::Type{MTKParams}, ::Val{:seat}) = true
StructEditor.skip_field(::Type{MTKParams}, ::Val{:car_and_suspension}) = true
StructEditor.skip_field(::Type{MTKParams}, ::Val{:wheel}) = true
StructEditor.skip_field(::Type{MTKParams}, ::Val{:road_data}) = true
StructEditor.skip_field(::Type{MTKParams}, ::Val{:err}) = true
StructEditor.skip_field(::Type{MTKParams}, ::Val{:flip}) = true
StructEditor.skip_field(::Type{MTKParams}, ::Val{:set_point}) = true

editor(prob, pars; idxs=[sys.road.s.u, sys.seat.body.s, sys.car_and_suspension.body.s, sys.wheel.body.s], solve_kwargs=(dtmax=0.1,)) #, mode=StructEditor.browser)
