using ModelingToolkitParameters
using Documenter

# DocMeta.setdocmeta!(ModelingToolkitParameters, :DocTestSetup, :(using ModelingToolkitParameters); recursive=true)

makedocs(;
    modules=[ModelingToolkitParameters],
    authors="Brad Carman <bradleygcarman@gmail.com>",
    sitename="ModelingToolkitParameters.jl",
    format=Documenter.HTML(;
        canonical="https://bradcarman.github.io/ModelingToolkitParameters.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        # "API Reference" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/bradcarman/ModelingToolkitParameters.jl",
    devbranch="main",
)
