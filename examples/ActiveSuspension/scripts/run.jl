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
@mtkparams pars = ActiveSuspensionModel.Model(pid=ActiveSuspensionModel.Controller(kp=100.0))
prob = ODEProblem(sys, pmap(sys, pars), (0, 10))
sol = solve(prob; dtmax=0.1)
lines(sol; idxs)

pars′ = copy(pars)

# Change Parameters using `pars` parameter object
pars′.pid.kp = 0.0
prob′ = remake(prob; p = pmap(sys, pars′))
sol = solve(prob′; dtmax=0.1)
lines(sol; idxs)

# Change Parameters (fast)
sys_cache = cache(sys, pars′)

pars′.pid.kp = 100.0
prob′′ = remake(prob, sys_cache, pmap(sys, pars′))  

sol = solve(prob′′; dtmax=0.1)

lines(sol; idxs)


# Implement StructEditor extension

using StructEditor

editor(prob, pars; idxs=[sys.road.s.u, sys.seat.body.s, sys.car_and_suspension.body.s, sys.wheel.body.s], solve_kwargs=(dtmax=0.1,), mode=StructEditor.browser)
