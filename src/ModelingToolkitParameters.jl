module ModelingToolkitParameters
using ModelingToolkit
using SymbolicIndexingInterface
using Symbolics
using InteractiveUtils: clipboard
using JuliaFormatter: format_text

export  Params, cache, update!, @params
include("parameters.jl")


end # module ModelingToolkitParameters
