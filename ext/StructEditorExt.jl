module StructEditorExt

using ModelingToolkit
using ModelingToolkitParameters
using StructEditor
using WGLMakie
using SciMLBase
using StructEditor.ShoelaceWidgets
using Logging

# Create a logger struct that holds a fallback "parent" logger
struct SolveLogger <: Logging.AbstractLogger
    parent_logger::Logging.AbstractLogger
end

# 1. CORRECTED: The minimum enabled level for this logger
Logging.min_enabled_level(logger::SolveLogger) = Logging.LogLevel(-1)

# 2. Catch everything that meets the min_enabled_level
Logging.shouldlog(logger::SolveLogger, level, _module, group, id) = true

# 3. Determine if the logger should catch exceptions during log generation
Logging.catch_exceptions(logger::SolveLogger) = false

progress = SLProgressBar(0.0; label="running", visible=false)

# 4. Intercept progress logs and pass the rest to the parent
function Logging.handle_message(logger::SolveLogger, level, message, _module, group, id, filepath, line; kwargs...)
    if level == Logging.LogLevel(-1)
        kw = Dict(kwargs)
        if haskey(kw, :progress)
            prog = kw[:progress]
            
            if prog isa Number
                percent = round(prog * 100, digits=1)
                progress.value[] = percent
            end
        end
    else
        # Pass non-progress logs to the parent logger
        Logging.handle_message(logger.parent_logger, level, message, _module, group, id, filepath, line; kwargs...)
    end
end

const solve_logger = SolveLogger(global_logger())


"""
    StructEditor.editor(prob::ODEProblem, params::MTKParams; kwargs...)

Launch an interactive GUI to edit parameters, solve, and visualize an `ODEProblem`.

This function creates a user interface with an embedded Makie plot and interactive buttons. 
It solves the initial problem and plots the variables specified by `idxs`. The interface 
includes a "run" button to re-solve the system with updated parameters and seamlessly 
update the plot via `Observable`s, and a "save" button to export the current parameters 
to a `test.toml` file.

# Arguments
- `prob::ODEProblem`: The differential equation problem to solve and visualize.
- `params::MTKParams`: The ModelingToolkit parameters associated with the problem.

# Keyword Arguments
- `idxs`: Indexices of the ODESolution to plot (see SymbolicIndexingInterface.jl for more information). Defaults to `[]`.
- `alg`: The specific SciML solver algorithm to use. Defaults to `nothing`, which utilizes the default polyalgorithm.
- `solve_kwargs::NamedTuple`: A named tuple of keyword arguments passed directly to `solve` (e.g., `(reltol=1e-8, saveat=0.1)`). Defaults to `(;)`.
- `kwargs...`: Any remaining keyword arguments are passed directly to the underlying UI `editor` function.

# Example
```julia
using ModelingToolkitParameters

# Enable extension by loading StructEditor and WGLMakie
using StructEditor
using WGLMakie

# Assuming my_prob and my_params are already defined
StructEditor.editor(
    my_prob, 
    my_params; 
    idxs = [1, 2],
    alg = Tsit5(), 
    solve_kwargs = (reltol=1e-6, abstol=1e-6)
)
```
"""
function StructEditor.editor(prob::ODEProblem, params::MTKParams; 
                             idxs=[], 
                             alg=nothing,          # Capture the solver algorithm
                             solve_kwargs=(;),     # Capture solver-specific kwargs
                             kwargs...)            # Capture remaining editor kwargs
    
    sys_cache = cache(prob.f.sys, params)

    # Splat the algorithm only if it was explicitly provided. 
    # This allows DifferentialEquations.jl to use its default polyalgorithm if alg is nothing.
    solver_args = isnothing(alg) ? () : (alg,)

    # Apply the solver args and kwargs to the initial solve
    sol = Observable(solve(prob, solver_args...; solve_kwargs...))
    
    name = ModelingToolkit.get_name(prob.f.sys)

    save = SLButton("save")
    on(save.value) do x
        save_parameters(params, "$name.toml")
    end

    fig = Figure(size=(750,450))
    ax = Axis(fig[1,1])
    if !isempty(idxs)
        lines!(ax, sol; idxs)
        axislegend(ax)
    end
    
    run = SLButton("run")
    on(run.value) do x
        progress.visible[] = true
        run.loading[] = true
        prob′ = remake(prob, sys_cache, pmap(prob.f.sys, params))
        
        # Apply the exact same solver args and kwargs to the update step
        sol[] = with_logger(solve_logger) do 
            solve(prob′, solver_args...; solve_kwargs..., progress=true)
        end 
        
        run.loading[] = false
        progress.visible[] = false
    end


    progress.visible[] = false

    # The remaining kwargs... are cleanly passed to the underlying editor
    editor(params; buttons = [save, run, progress, fig], kwargs...)
end

end # module
