using ActiveSuspensionModel
using ModelingToolkitParameters
using ModelingToolkit

@mtkbuild sys = ActiveSuspensionModel.Model()
ModelPars = build_params(ActiveSuspensionModel.Model; globals=[:g=>ActiveSuspensionModel.g])
sys_pars = ModelPars()
prob = ODEProblem(sys, sys => sys_pars, (0, 10))