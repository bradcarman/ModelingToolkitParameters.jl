using ActiveSuspensionModel
using ModelingToolkitParameters
using ModelingToolkit
using OrdinaryDiffEq
using Plots

@mtkbuild sys = ActiveSuspensionModel.Model()
sys_pars = ModelParams(ActiveSuspensionModel.Model)
prob = ODEProblem(sys, sys => sys_pars, (0, 10))
sol = solve(prob)
plot(sol; idxs=[sys.road.s.u, sys.seat.body.s, sys.car_and_suspension.body.s, sys.wheel.body.s])

sys_cache = cache(sys, sys_pars)

# change parameter
sys_pars.seat.damper.d = 100.0

prob = remake(prob, sys_cache, sys => sys_pars)
sol = solve(prob)
plot(sol; idxs=[sys.road.s.u, sys.seat.body.s, sys.car_and_suspension.body.s, sys.wheel.body.s])

