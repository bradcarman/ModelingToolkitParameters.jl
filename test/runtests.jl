using Test
using ModelingToolkit
using ModelingToolkitParameters
using SciMLBase

include("model.jl")

include("parent_bindings.jl")

@mtkcompile rc_model = RCModel()
rc_model_params = MTKParams(RCModel)
rc_model_params.capacitor.m = 1 #set missing value
prob = ODEProblem(rc_model, rc_model => rc_model_params, (0, 10.0))


# slow but easy update method...
rc_model_params.resistor.R = 1.5                            # change param struct 
prob′ = remake(prob; p = pmap(rc_model, rc_model_params))       # remake prob (standard call with new pmap)
@test prob′.ps[rc_model.resistor.R] == 1.5                   # check parameter update


# fast update method (mutate prob)...
setters = cache(rc_model, rc_model_params)                    # get a cache of SymbolicIndexingInterface pset
rc_model_params.resistor.R = 2.0                            # change param struct
update!(prob, setters, pmap(rc_model, rc_model_params))         # update the prob
@test prob.ps[rc_model.resistor.R] == 2.0                   # check parameter update



# fast update method (copy prob)...
rc_model_params.resistor.R = 3.0                             # change param struct
prob′ = remake(prob, setters, pmap(rc_model, rc_model_params))   # use remake with pset cache and updated pmap
@test prob.ps[rc_model.resistor.R] == 2.0                    # check prob is not mutated
@test prob′.ps[rc_model.resistor.R] == 3.0                   # check new prob′ value
