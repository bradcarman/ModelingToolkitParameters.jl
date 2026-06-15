using ActiveSuspensionModel
using ModelingToolkit
using OrdinaryDiffEq
using ModelingToolkitParameters
using WGLMakie

@mtkcompile sys = ActiveSuspensionModel.Model()
prob = ODEProblem(sys, [], (0, 10))
sol = solve(prob)
idxs = [sys.road.s.u, sys.seat.body.s, sys.car_and_suspension.body.s, sys.wheel.body.s]

lines(sol; idxs)

# Change Parameters
@mtkparams sys_pars = ActiveSuspensionModel.Model()
sys_pars.pid.kd = 200.0
prob′ = remake(prob; p = pmap(sys, sys_pars))
sol = solve(prob′)

lines(sol; idxs)

# Change Parameters (fast)
sys_cache = cache(sys, sys_pars)

sys_pars.pid.kd = 2000.0
prob′′ = remake(prob, sys_cache, pmap(sys, sys_pars))  

sol = solve(prob′′)

lines(sol; idxs)


# Implement StructEditor extension

using StructEditor
editor(prob, sys_pars; idxs=[sys.road.s.u, sys.seat.body.s, sys.car_and_suspension.body.s, sys.wheel.body.s], solve_kwargs=(dt=1e-4, adaptive=false)) #, mode=StructEditor.browser)
