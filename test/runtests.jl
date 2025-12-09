using Test
using ModelingToolkit
using ModelingToolkitParameters

include("model.jl")

@mtkcompile rc_model = RCModel()
rc_model_params = RCModelParams()
prob = ODEProblem(rc_model, rc_model => rc_model_params, (0, 10.0))


setters = cache(rc_model, RCModelParams)
rc_model_params.resistor.R = 2.0
update!(prob, setters, rc_model => rc_model_params)

@test prob.ps[rc_model.resistor.R] == 2.0

rc_model_params.resistor.R = 3.0
prob′ = remake(prob, setters, rc_model => rc_model_params)
@test prob.ps[rc_model.resistor.R] == 2.0
@test prob′.ps[rc_model.resistor.R] == 3.0





ModelingToolkitParameters.params(RCModel)
