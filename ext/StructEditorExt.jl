module StructEditorExt

using ModelingToolkit
using ModelingToolkitParameters
using StructEditor
using WGLMakie
using SciMLBase
using StructEditor.ShoelaceWidgets
using Logging
using StructEditor.Bonito

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

function StructEditor.make_control!(value::Observable{<: MTKParams}, ::Type{T}, sname::Symbol, dirty=identity) where T <: Number
    name = string(sname)
    val = getproperty(value[], sname)
    h = StructEditor.help(typeof(value[]), Val(sname) )

    parent = ModelingToolkitParameters.get_parent(value[])
    defs = ModelingToolkitParameters.get_defs(value[])

    sym = ModelingToolkitParameters.getproperty(parent, sname)

    setmin=NaN
    setmax=NaN
    if ModelingToolkit.hasbounds(sym)
        bounds = ModelingToolkit.getbounds(sym)
    
        setmin = bounds[1]
        setmax = bounds[2]
    end

    y = SLInput(val; label=name, help=h, select_on_focus=true, min=setmin, max=setmax)
    on(y.value) do x

        # println(":: y ($name): $x")
        if ismutable(value[])
            setproperty!(value[], sname, T(x))
        else
            value[] = set(value[], PropertyLens(sname), T(x))
        end

        
        dirty(true)
    end

    return [y]
end



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
                             auto_run=true,
                             path="/", 
                             mode=StructEditor.vscode, 
                             server = nothing,
                             icon="https://icons.getbootstrap.com/assets/icons/play.svg", 
                             title=ModelingToolkit.get_name(prob.f.sys),
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

    fig = Figure(size=(750,450))
    ax = Axis(fig[1,1])
    if !isempty(idxs)
        lines!(ax, sol; idxs)
        axislegend(ax)
    end
    
    function do_run()
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


    run = SLButton("run")
    on(run.value) do x
        do_run()
    end

    progress.visible[] = false

    save_function = StructEditor.SaveFunction(func = () -> save_parameters(params, "$name.toml"))   

    app = App() do session

        # Build the form (and its widgets/Observables) fresh per session. Bonito
        # widgets carry mutable per-session state, so a form shared across sessions
        # breaks on the 2nd open (e.g. an SLSelect's value binding collides and the
        # client sends NaN on change). Constructing inside the closure isolates each open.
        obs_value = Observable(params)
        if auto_run
            on(obs_value) do x
                do_run()
            end
        end

        form = StructEditor.make_form(obs_value; save_function, buttons = [run, progress, fig], kwargs...)

        StructEditor.page(form; title, icon)
    end

    return StructEditor.run_app(app; mode, server, path)
end

end # module
