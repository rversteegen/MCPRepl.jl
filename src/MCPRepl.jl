module MCPRepl

using REPL
using HTTP
using JSON3

include("MCPServer.jl")
include("setup.jl")

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, MIME("text/plain"), x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

function trim_long_content(content::String; max_lines::Int = 100)
    lines = split(content, '\n')
    if length(lines) <= max_lines
        return content
    end

    # Show first half and last half
    context_lines = max_lines ÷ 2
    first_part = join(lines[1:context_lines], '\n')
    last_part = join(lines[end-context_lines+1:end], '\n')

    omitted_count = length(lines) - max_lines
    middle = "\n... [$(omitted_count) lines omitted] ...\n"

    return first_part * middle * last_part
end

# The active REPL is only usable once its interface has been created.
# When Julia is started as `julia -i -e 'MCPRepl.start!()'` (as the
# mcp-julia-harness does), the MCP server comes up before the interactive REPL
# exists, so tool calls can arrive while `Base.active_repl` is still being set
# up. Wait for the REPL instead of erroring out.
function repl_is_ready(repl)
    repl === nothing && return false
    return repl isa REPL.LineEditREPL &&
           isdefined(repl, :interface) &&
           isdefined(repl, :backendref) &&
           repl.mistate !== nothing
end

function wait_for_active_repl(; timeout::Real = 30.0)
    deadline = time() + timeout
    while true
        if isdefined(Base, :active_repl)
            repl = getfield(Base, :active_repl)
            repl_is_ready(repl) && return repl
        end
        time() >= deadline && return nothing
        sleep(0.05)
    end
end

# `redirect_stdout` / `redirect_stderr` mutate process-global state and restore
# whatever stream was installed when they were entered. Two overlapping tool
# calls therefore restore each other's capture pipes instead of the terminal,
# and `stdout` is left pointing at a closed pipe -- after which every echo the
# REPL writes disappears (the "agent>" line shows up empty and no output ever
# reaches the terminal again). Serialize evaluation, and always restore the
# streams that were live when the server started.
const EXEC_LOCK = ReentrantLock()
const ORIG_STDOUT = Ref{Union{Nothing, IO}}(nothing)
const ORIG_STDERR = Ref{Union{Nothing, IO}}(nothing)

function remember_std_streams!()
    ORIG_STDOUT[] === nothing && (ORIG_STDOUT[] = stdout)
    ORIG_STDERR[] === nothing && (ORIG_STDERR[] = stderr)
    return nothing
end

function restore_std_streams!()
    o = ORIG_STDOUT[]
    o !== nothing && o !== stdout && redirect_stdout(o)
    e = ORIG_STDERR[]
    e !== nothing && e !== stderr && redirect_stderr(e)
    return nothing
end

# Echoes must go to the REPL's own terminal, never to the global `stdout`,
# which is redirected into a capture pipe while user code runs.
function repl_outstream(repl)
    try
        return REPL.outstream(repl)
    catch
        return something(ORIG_STDOUT[], stdout)
    end
end

function execute_repllike(str)
    return lock(EXEC_LOCK) do
        restore_std_streams!()
        try
            return _execute_repllike(str)
        finally
            restore_std_streams!()
        end
    end
end

function _execute_repllike(str)
    # Check for Pkg.activate usage
    # if contains(str, "activate(") && !contains(str, r"#.*overwrite no-activate-rule")
    #     return """
    #         ERROR: Using Pkg.activate to change environments is not allowed.
    #         You should assume you are in the correct environment for your tasks.
    #         You may use Pkg.status() to see the current environment and available packages.
    #         If you need to use a third-party 'activate' function, add '# overwrite no-activate-rule' at the end of your command.
    #     """
    # end
    if contains(str, "Pkg.add(")
        return """
            ERROR: Using Pkg.add to install packages is not allowed.
            You should assume all necessary packages are already installed in the environment.
            If you need another package, prompt the user!
        """
    end
    # Check for varinfo() usage which is slow and problematic
    # if contains(str, "varinfo(")
    #     return """
    #         ERROR: Using varinfo() is not allowed because it takes too long to execute.
    #         Use the investigate_environment tool instead to get information about the Julia environment.
    #         If unclear, ask the user.
    #     """
    # end
    # eval using/import to suppress interactive ask for instllation
    if contains(str, r"(^|\n)using\s") || contains(str, r"(^|\n)import\s")
        # Replace each import/using statement with @eval prefix
        str = replace(str, r"(^|\n)(using\s[^\n]*)" => s"\1@eval \2")
        str = replace(str, r"(^|\n)(import\s[^\n]*)" => s"\1@eval \2")
    end


    # alternative approach to @eval on using/import?
    # old_stdin = stdin
    # redirect_stdin(devnull)
    # try
    #     using Optim
    # catch e
    #     rethrow(e)
    # finally
    #     redirect_stdin(old_stdin)
    # end

    if isempty(strip(str))
        return """
            ERROR: no `expression` argument was received, so nothing was evaluated.
            Pass the Julia code to run in the `expression` parameter.
        """
    end

    repl = wait_for_active_repl()
    if repl === nothing
        return """
            The Julia REPL is not ready yet. It may still be starting up (e.g. right after a restart).
            Wait a moment and try again.
        """
    end
    # expr = Meta.parse(str)
    expr = Base.parse_input_line(str)
    backend = repl.backendref

    termout = repl_outstream(repl)
    REPL.prepare_next(repl)
    printstyled(termout, "\nagent> ", color=:red, bold=true)
    print(termout, str, "\n")

    # Capture stdout/stderr during execution
    captured_output = Pipe()
    saved_stdout, saved_stderr = stdout, stderr
    response = try
        redirect_stdout(captured_output)
        redirect_stderr(captured_output)
        # Julia 1.12+ renamed eval_with_backend to eval_on_backend
        if VERSION >= v"1.12"
            REPL.eval_on_backend(expr, backend)
        else
            REPL.eval_with_backend(expr, backend)
        end
    finally
        # Restore first, so a failure below can never leave the process with a
        # dead `stdout`; closing the writer unblocks the `read` that follows.
        redirect_stdout(saved_stdout)
        redirect_stderr(saved_stderr)
        try
            close(Base.pipe_writer(captured_output))
        catch
        end
    end
    captured_content = read(captured_output, String)
    # reshow the stuff which was printed to stdout/stderr before
    print(termout, captured_content)

    disp = IOBufferDisplay()

    # generate printout, err goes to disp.err, val goes to "specialdisplay" disp
    if VERSION >= v"1.11"
        REPL.print_response(disp.io, response, backend, !REPL.ends_with_semicolon(str), false, disp)
    else
        REPL.print_response(disp.io, response, !REPL.ends_with_semicolon(str), false, disp)
    end

    # generate the printout again for the "normal" repl
    REPL.print_response(repl, response, !REPL.ends_with_semicolon(str), repl.hascolor)

    REPL.prepare_next(repl)
    REPL.LineEdit.refresh_line(repl.mistate)

    # Combine captured output with display output
    display_content = String(take!(disp.io))
    
    # Trim long content
    captured_content = trim_long_content(captured_content)
    display_content = trim_long_content(display_content)

    return captured_content*display_content
end

SERVER = Ref{Union{Nothing, MCPServer}}(nothing)

# Exit code the restart_repl tool uses to signal the launching harness
# (mcp-julia-harness) to restart the Julia process.
const RESTART_EXIT_CODE = 42

function repl_status_report()
    if !isdefined(Main, :Pkg)
        error("Expect Main.Pkg to be defined.")
    end
    Pkg = Main.Pkg

    try
        # Basic environment info
        println("🔍 Julia Environment Investigation")
        println("=" ^ 50)
        println()

        # Current directory
        println("📁 Current Directory:")
        println("   $(pwd())")
        println()

        # Active project
        active_proj = Base.active_project()
        println("📦 Active Project:")
        if active_proj !== nothing
            println("   Path: $active_proj")
            try
                project_data = Pkg.TOML.parsefile(active_proj)
                if haskey(project_data, "name")
                    println("   Name: $(project_data["name"])")
                else
                    println("   Name: $(basename(dirname(active_proj)))")
                end
                if haskey(project_data, "version")
                    println("   Version: $(project_data["version"])")
                end
            catch e
                println("   Error reading project info: $e")
            end
        else
            println("   No active project")
        end
        println()

        # Package status
        println("📚 Package Environment:")
        try
            # Get package status (suppress output)
            pkg_status = redirect_stdout(devnull) do
                Pkg.status(; mode = Pkg.PKGMODE_MANIFEST)
            end

            # Parse dependencies for development packages
            deps = Pkg.dependencies()
            dev_packages = Dict{String, String}()

            for (uuid, pkg_info) in deps
                if pkg_info.is_direct_dep && pkg_info.is_tracking_path
                    dev_packages[pkg_info.name] = pkg_info.source
                end
            end

            # Add current environment package if it's a development package
            if active_proj !== nothing
                try
                    project_data = Pkg.TOML.parsefile(active_proj)
                    if haskey(project_data, "uuid")
                        pkg_name = get(project_data, "name", basename(dirname(active_proj)))
                        pkg_dir = dirname(active_proj)
                        # This is a development package since we're in its source
                        dev_packages[pkg_name] = pkg_dir
                    end
                catch
                    # Not a package, that's fine
                end
            end

            # Check if current environment is itself a package and collect its info
            current_env_package = nothing
            if active_proj !== nothing
                try
                    project_data = Pkg.TOML.parsefile(active_proj)
                    if haskey(project_data, "uuid")
                        pkg_name = get(project_data, "name", basename(dirname(active_proj)))
                        pkg_version = get(project_data, "version", "dev")
                        pkg_uuid = project_data["uuid"]
                        current_env_package = (name = pkg_name, version = pkg_version, uuid = pkg_uuid, path = dirname(active_proj))
                    end
                catch
                    # Not a package environment, that's fine
                end
            end

            # Separate development packages from regular packages
            dev_deps = []
            regular_deps = []

            for (uuid, pkg_info) in deps
                if pkg_info.is_direct_dep
                    if haskey(dev_packages, pkg_info.name)
                        push!(dev_deps, pkg_info)
                    else
                        push!(regular_deps, pkg_info)
                    end
                end
            end

            # List development packages first (with current environment package at the top if applicable)
            has_dev_packages = !isempty(dev_deps) || current_env_package !== nothing
            if has_dev_packages
                println("   🔧 Development packages (tracked by Revise):")

                # Show current environment package first if it exists
                if current_env_package !== nothing
                    println("      $(current_env_package.name) v$(current_env_package.version) [CURRENT ENV] => $(current_env_package.path)")
                    try
                        # Try to get canonical path using pkgdir
                        pkg_dir = pkgdir(current_env_package.name)
                        if pkg_dir !== nothing && pkg_dir != current_env_package.path
                            println("         pkgdir(): $pkg_dir")
                        end
                    catch
                        # pkgdir might fail, that's okay
                    end
                end

                # Then show other development packages
                for pkg_info in dev_deps
                    # Skip if this is the same as the current environment package
                    if current_env_package !== nothing && pkg_info.name == current_env_package.name
                        continue
                    end
                    println("      $(pkg_info.name) v$(pkg_info.version) => $(dev_packages[pkg_info.name])")
                    try
                        # Try to get canonical path using pkgdir
                        pkg_dir = pkgdir(pkg_info.name)
                        if pkg_dir !== nothing && pkg_dir != dev_packages[pkg_info.name]
                            println("         pkgdir(): $pkg_dir")
                        end
                    catch
                        # pkgdir might fail, that's okay
                    end
                end
                println()
            end

            # List regular packages second
            if !isempty(regular_deps)
                println("   📦 Other packages in environment:")
                for pkg_info in regular_deps
                    println("      $(pkg_info.name) v$(pkg_info.version)")
                end
            end

            # Handle empty environment
            if isempty(deps) && current_env_package === nothing
                println("   No packages in environment")
            end

        catch e
            println("   Error getting package status: $e")
        end

        println()
        println("🔄 Revise.jl Status:")
        try
            if isdefined(Main, :Revise)
                println("   ✅ Revise.jl is loaded and active")
                println("   📝 Development packages will auto-reload on changes")
            else
                println("   ⚠️  Revise.jl is not loaded")
            end
        catch
            println("   ❓ Could not determine Revise.jl status")
        end

        return nothing

    catch e
        println("Error generating environment report: $e")
        return nothing
    end
end

function start!(; verbose::Bool = true)
    remember_std_streams!()
    SERVER[] !== nothing && stop!() # Stop existing server if running

    usage_instructions_tool = MCPTool(
        "usage_instructions",
        "Get instructions for proper Julia REPL usage.",
        Dict(
            "type" => "object",
            "properties" => Dict(),
            "required" => []
        ),
        args -> begin
            try
                workflow_path = joinpath(dirname(dirname(@__FILE__)), "prompts", "julia_repl_workflow.md")
                if isfile(workflow_path)
                    return read(workflow_path, String)
                else
                    return "Error: julia_repl_workflow.md not found at $workflow_path"
                end
            catch e
                return "Error reading usage instructions: $e"
            end
        end
    )

    repl_tool = MCPTool(
        "exec_repl",
        """
        Execute Julia code in a shared, persistent REPL session to avoid startup latency.

        Before using this tool, you MUST first call the `usage_instructions` tool.

        Prefer the REPL instead of `julia` bash commands.

        The tool returns raw text output containing: all printed content from stdout and stderr streams, plus the mime text/plain representation of the expression's return value (unless the expression ends with a semicolon).

        You may use this REPL to
        - execute test sets
        - get julia function documentation (i.e. send @doc functionname)
        - investigate the environment
        """,
        MCPRepl.text_parameter("expression", "Julia expression to evaluate (eg `import Pkg; Pkg.status()`"),
        args -> begin
            try
                execute_repllike(get(args, "expression", ""))
            catch e
                println(something(ORIG_STDOUT[], stdout), "Error during execute_repllike: ", e)
                "Apparently there was an **internal** error to the MCP server: $e"
            end
        end
    )

    whitespace_tool = MCPTool(
        "remove-trailing-whitespace",
        """Remove trailing whitespace from all lines in a file.

        This tool should be called to clean up any trailing spaces that AI agents tend to leave in files after editing.

        **Usage Guidelines:**
        - For multiple file edits: Call once on each modified file at the very end, before handing back to the user
        - Always call this tool on files you've edited to maintain clean, professional code formatting

        The tool efficiently removes all types of trailing whitespace (spaces, tabs, mixed) from every line in the file.""",
        MCPRepl.text_parameter("file_path", "Absolute path to the file to clean up"),
        args -> begin
            try
                file_path = get(args, "file_path", "")
                if isempty(file_path)
                    return "Error: file_path parameter is required"
                end

                if !isfile(file_path)
                    return "Error: File does not exist: $file_path"
                end

                # Use sed to remove trailing whitespace (similar to emacs delete-trailing-whitespace)
                # This removes all trailing whitespace characters from each line
                result = run(pipeline(`sed -i 's/[[:space:]]*$//' $file_path`, stderr=devnull))

                if result.exitcode == 0
                    return "Successfully removed trailing whitespace from $file_path"
                else
                    return "Error: Failed to remove trailing whitespace from $file_path"
                end
            catch e
                return "Error removing trailing whitespace: $e"
            end
        end
    )

    investigate_tool = MCPTool(
        "investigate_environment",
        """Investigate the current Julia environment including pwd, active project, packages, and development packages with their paths.

        This tool provides comprehensive information about:
        - Current working directory
        - Active project and its details
        - All packages in the environment with development status
        - Development packages with their file system paths
        - Current environment package status
        - Revise.jl status for hot reloading

        This is useful for understanding the development setup and debugging environment issues.""",
        Dict(
            "type" => "object",
            "properties" => Dict(),
            "required" => []
        ),
        args -> begin
            try
                execute_repllike("MCPRepl.repl_status_report()")
            catch e
                "Error investigating environment: $e"
            end
        end
    )

    restart_tool = MCPTool(
        "restart_repl",
        """Restart the Julia MCP REPL process.

        Use this when the REPL session is in a broken or unrecoverable state (e.g. Revise errors, corrupted state).
        julia will be relaunched, restarting the MCP server.

        **Wait a few seconds** after calling this tool.""",
        Dict(
            "type" => "object",
            "properties" => Dict(),
            "required" => []
        ),
        args -> begin
            @async begin
                sleep(0.5)
                exit(RESTART_EXIT_CODE)
            end
            "Restarting the Julia process... **Wait a few seconds** before using any other tool."
        end
    )

    # Create and start server
    #whitespace_tool, , investigate_tool
    SERVER[] = start_mcp_server([usage_instructions_tool, repl_tool, restart_tool], 3000; verbose=verbose)

    if isdefined(Base, :active_repl)
        repl = getfield(Base, :active_repl)
        isdefined(repl, :interface) ? set_prefix!(repl) : set_prefix_when_ready!(repl)
    else
        atreplinit(set_prefix_when_ready!)
    end
    nothing
end

# `atreplinit` hooks run before the REPL interface has been created (Julia
# >= 1.12), so touching `repl.interface` from there throws an `UndefRefError`.
# Defer the prompt update until the interface is available; blocking inside the
# hook would prevent the REPL (which creates the interface in another task)
# from ever starting.
function set_prefix_when_ready!(repl; timeout::Real = 10.0)
    @async begin
        deadline = time() + timeout
        while !isdefined(repl, :interface)
            time() >= deadline && return nothing
            sleep(0.05)
        end
        set_prefix!(repl)
        return nothing
    end
    return nothing
end

function set_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, "✻ julia> ")
    return nothing
end

function unset_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, REPL.JULIA_PROMPT)
    return nothing
end

function get_mainmode(repl)
    if isdefined(REPL.LineEdit, :find_mode) && hasmethod(REPL.LineEdit.find_mode, Tuple{Any,Symbol})
        mode = REPL.LineEdit.find_mode(repl.interface.modes, :julia)
        !isnothing(mode) && return mode
    end

    modes = filter(repl.interface.modes) do mode
        mode isa REPL.LineEdit.Prompt && mode.prompt isa Function && contains(mode.prompt(), "julia>")
    end

    if isempty(modes)
        error("Could not find Julia REPL main mode")
    end

    return first(modes)
end

function stop!()
    if SERVER[] !== nothing
        println("Stop existing server...")
        stop_mcp_server(SERVER[])
        SERVER[] = nothing
        if isdefined(Base, :active_repl)
            repl = getfield(Base, :active_repl)
            isdefined(repl, :interface) && unset_prefix!(repl) # Reset the prompt prefix
        end
    else
        println("No server running to stop.")
    end
end

end #module
