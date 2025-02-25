module JuliaFormatter

using CSTParser
using Tokenize
using DataStructures
using Pkg.TOML: parsefile
using Documenter.DocTests: repl_splitter
import CommonMark: block_modifier
using CommonMark:
    AdmonitionRule,
    CodeBlock,
    enable!,
    FootnoteRule,
    markdown,
    MathRule,
    Parser,
    Rule,
    TableRule

export format, format_text, format_file, format_md, DefaultStyle, YASStyle, BlueStyle

abstract type AbstractStyle end

@inline options(s::AbstractStyle) = NamedTuple()

"""
    DefaultStyle

The default formatting style. See the [Style](@ref) section of the documentation
for more details.

See also: [`BlueStyle`](@ref), [`YASStyle`](@ref)
"""
struct DefaultStyle <: AbstractStyle
    innerstyle::Union{Nothing,AbstractStyle}
end
DefaultStyle() = DefaultStyle(nothing)

@inline getstyle(s::DefaultStyle) = s.innerstyle === nothing ? s : s.innerstyle
function options(s::DefaultStyle)
    return (;
        indent = 4,
        margin = 92,
        always_for_in = false,
        whitespace_typedefs = false,
        whitespace_ops_in_indices = false,
        remove_extra_newlines = false,
        import_to_using = false,
        pipe_to_function_call = false,
        short_to_long_function_def = false,
        always_use_return = false,
        whitespace_in_kwargs = true,
        annotate_untyped_fields_with_any = true,
        format_docstrings = false,
        align_struct_field = false,
        align_assignment = false,
        align_conditional = false,
        align_pair_arrow = false,
        conditional_to_if = false,
    )
end

include("document.jl")
include("options.jl")
include("state.jl")
include("fst.jl")
include("passes.jl")
include("align.jl")
include("nest_utils.jl")

include("styles/default/pretty.jl")
include("styles/default/nest.jl")
include("styles/yas/pretty.jl")
include("styles/yas/nest.jl")
include("styles/blue/pretty.jl")
include("styles/blue/nest.jl")

include("print.jl")

include("markdown.jl")

const UNIX_TO_WINDOWS = r"\r?\n" => "\r\n"
const WINDOWS_TO_UNIX = "\r\n" => "\n"
function choose_line_ending_replacer(text)
    rn = count("\r\n", text)
    n = count(r"(?<!\r)\n", text)
    n >= rn ? WINDOWS_TO_UNIX : UNIX_TO_WINDOWS
end
normalize_line_ending(s::AbstractString, replacer = WINDOWS_TO_UNIX) = replace(s, replacer)

"""
    format_text(
        text::AbstractString;
        style::AbstractStyle = DefaultStyle(),
        indent::Int = 4,
        margin::Int = 92,
        always_for_in::Bool = false,
        whitespace_typedefs::Bool = false,
        whitespace_ops_in_indices::Bool = false,
        remove_extra_newlines::Bool = false,
        import_to_using::Bool = false,
        pipe_to_function_call::Bool = false,
        short_to_long_function_def::Bool = false,
        always_use_return::Bool = false,
        whitespace_in_kwargs::Bool = true,
        annotate_untyped_fields_with_any::Bool = true,
        format_docstrings::Bool = false,
        align_struct_field::Bool = false,
        align_conditional::Bool = false,
        align_assignment::Bool = false,
        align_pair_arrow::Bool = false,
        conditional_to_if = false,
        normalize_line_endings = "auto",
    )::String

Formats a Julia source passed in as a string, returning the formatted
code as another string.

## Formatting Options

### `indent`

The number of spaces used for an indentation.

### `margin`

The maximum length of a line. Code exceeding this margin will
be formatted across multiple lines.

### `always_for_in`

If true, `=` is always replaced with `in` if part of a `for` loop condition.
For example, `for i = 1:10` will be transformed to `for i in 1:10`.

### `whitespace_typedefs`

If true, whitespace is added for type definitions. Make this `true`
if you prefer `Union{A <: B, C}` to `Union{A<:B,C}`.

### `whitespace_ops_in_indices`

If true, whitespace is added for binary operations in indices. Make this
`true` if you prefer `arr[a + b]` to `arr[a+b]`. Additionally, if there's
a colon `:` involved, parenthesis will be added to the LHS and RHS.

Example: `arr[(i1 + i2):(i3 + i4)]` instead of `arr[i1+i2:i3+i4]`.

### `remove_extra_newlines`

If true, superflous newlines will be removed. For example:

```julia
module M



a = 1

function foo()


    return nothing

end


b = 2


end
```

is rewritten as

```julia
module M

a = 1

function foo()
    return nothing
end

b = 2

end
```

Modules are the only type of code block allowed to keep a single newline
prior to the intial or after the final piece of code.

### `import_to_using`

If true, `import` expressions are rewritten to `using` expressions
in the following cases:

```julia
import A

import A, B, C
```

is rewritten to:

```julia
using A: A

using A: A
using B: B
using C: C
```

### `pipe_to_function_call`

If true, `x |> f` is rewritten to `f(x)`.

### `short_to_long_function_def`

Transforms a *short* function definition

```julia
f(arg1, arg2) = body
```

to a *long* function definition

```julia
function f(arg2, arg2)
    body
end
```

### `always_use_return`

If true, `return` will be prepended to the last expression where
applicable in function definitions, macro definitions, and do blocks.

Example:

```julia
function foo()
    expr1
    expr2
end
```

to

```julia
function foo()
    expr1
    return expr2
end
```

### `whitespace_in_kwargs`

If true, `=` in keyword arguments will be surrounded by whitespace.

```julia
f(; a=4)
```

to

```julia
f(; a = 4)
```

An exception to this is if the LHS ends with "!" then even if `whitespace_in_kwargs` is
false, `=` will still be surrounded by whitespace. The logic behind this intervention being
on the following parse the `!` will be treated as part of `=`, as in a "not equal" binary
operation. This would change the semantics of the code and is therefore disallowed.

### `annotate_untyped_fields_with_any`

Annotates fields in a type definitions with `::Any` if no type annotation is provided:

```julia
struct A
    arg1
end
```

to

```julia
struct A
    arg1::Any
end
```

### `format_docstrings`

Format code docstrings with the same options used for the code source.

Markdown is formatted with [`CommonMark`](https://github.com/MichaelHatherly/CommonMark.jl) alongside Julia code.

### `align_*`

See `Custom Alignment` documentation.

### `conditional_to_if`


If the conditional `E ? A : B` exceeds the maximum margin converts it into the equivalent `if` block:

```julia
if E
    A
else
    B
end
```

### `normalize_line_endings`

One of `"unix"` (normalize all `\r\n` to `\n`), `"windows"` (normalize all `\n` to `\r\n`), `"auto"` (automatically
choose based on which line ending is more common in the file).
"""
function format_text(text::AbstractString; style::AbstractStyle = DefaultStyle(), kwargs...)
    return format_text(text, style; kwargs...)
end

function format_text(text::AbstractString, style::AbstractStyle; kwargs...)
    isempty(text) && return text
    opts = Options(; merge(options(style), kwargs)...)
    return format_text(text, style, opts)
end

function format_text(text::AbstractString, style::AbstractStyle, opts::Options)
    cst, ps = CSTParser.parse(CSTParser.ParseState(text), true)
    line, offset = ps.lt.endpos
    ps.errored && error("Parsing error for input occurred on line $line, offset: $offset")
    cst.args[1].kind === Tokens.NOTHING && length(cst) == 1 && return text
    return format_text(cst, style, State(Document(text), opts))
end

function format_text(cst::CSTParser.EXPR, style::AbstractStyle, s::State)
    t = pretty(style, cst, s)
    hascomment(s.doc, t.endline) && (add_node!(t, InlineComment(t.endline), s))

    s.opts.pipe_to_function_call && pipe_to_function_call_pass!(t)

    flatten_fst!(t)

    if s.opts.align_struct_field ||
       s.opts.align_conditional ||
       s.opts.align_assignment ||
       s.opts.align_pair_arrow
        align_fst!(t, s.opts)
    end

    nest!(style, t, s)

    s.line_offset = 0
    io = IOBuffer()

    # Print comments and whitespace before code.
    if t.startline > 1
        format_check(io, Notcode(1, t.startline - 1), s)
        print_leaf(io, Newline(), s)
    end

    print_tree(io, t, s)

    if t.endline < length(s.doc.range_to_line)
        print_leaf(io, Newline(), s)
        format_check(io, Notcode(t.endline + 1, length(s.doc.range_to_line)), s)
    end

    text = String(take!(io))

    replacer = if s.opts.normalize_line_endings === "unix"
        WINDOWS_TO_UNIX
    elseif s.opts.normalize_line_endings === "windows"
        UNIX_TO_WINDOWS
    else
        choose_line_ending_replacer(s.doc.text)
    end
    text = normalize_line_ending(text, replacer)

    _, ps = CSTParser.parse(CSTParser.ParseState(text), true)
    line, offset = ps.lt.endpos
    ps.errored && error(
        "Parsing error for formatted text:\n\n$text\n\n Error occured on line $line, offset $offset.",
    )
    return text
end

"""
    format_file(
        filename::AbstractString;
        overwrite::Bool = true,
        verbose::Bool = false,
        format_markdown::Bool = false,
        format_options...,
    )::Bool

Formats the contents of `filename` assuming it's a `.jl` or `.md` file. If it's a
`.md` file, Julia code blocks will be formatted in addition to the markdown being
normalized.

### File Options

If `overwrite` is `true` the file will be reformatted in place, overwriting
the existing file; if it is `false`, the formatted version of `foo.jl` will
not be written anywhere.

If `verbose` is `true` details related to formatting the file will be printed
to `stdout`.

If `format_markdown` is true, `.md` files are formatted.

### Formatting Options

See [`format_text`](@ref) for description of formatting options.

### Output

Returns a boolean indicating whether the file was already formatted (`true`)
or not (`false`).
"""
function format_file(
    filename::AbstractString;
    overwrite::Bool = true,
    verbose::Bool = false,
    format_markdown::Bool = false,
    format_options...,
)::Bool
    path, ext = splitext(filename)
    shebang_pattern = r"^#!\s*/.*\bjulia[0-9.-]*\b"
    formatted_str = if ext == ".md"
        format_markdown || return true
        verbose && println("Formatting $filename")
        str = String(read(filename))
        format_md(str; format_options...)
    elseif ext == ".jl" || match(shebang_pattern, readline(filename)) !== nothing
        verbose && println("Formatting $filename")
        str = String(read(filename))
        format_text(str; format_options...)
    else
        error("$filename must be a Julia (.jl) or Markdown (.md) source file")
    end
    formatted_str = replace(formatted_str, r"\n*$" => "\n")

    if overwrite
        write(filename, formatted_str)
    end
    return formatted_str == str
end

"""
    format_file(filename::AbstractString, style::AbstractStyle; kwargs...)::Bool
"""
function format_file(filename::AbstractString, style::AbstractStyle; kwargs...)
    return format_file(filename; style = style, kwargs...)
end

const CONFIG_FILE_NAME = ".JuliaFormatter.toml"

"""
    format(
        paths; # a path or collection of paths
        options...,
    )::Bool

Recursively descend into files and directories, formatting any `.jl`
files by calling `format_file` on them.

See [`format_file`](@ref) and [`format_text`](@ref) for a description of the options.

This function will look for `.JuliaFormatter.toml` in the location of the file being
formatted, and searching *up* the file tree until a config file is (or isn't) found.
When found, the configurations in the file will overwrite the given `options`.
See [Configuration File](@ref) for more details.

### Output

Returns a boolean indicating whether the file was already formatted (`true`)
or not (`false`).
"""
function format(paths; options...)::Bool
    dir2config = Dict{String,Any}()
    already_formatted = true
    function find_config_file(dir)
        next_dir = dirname(dir)
        config = if (next_dir == dir || # ensure to escape infinite recursion
                     isempty(dir)) # reached to the system root
            nothing
        elseif haskey(dir2config, dir)
            dir2config[dir]
        else
            path = joinpath(dir, CONFIG_FILE_NAME)
            isfile(path) ? parse_config(path) : find_config_file(next_dir)
        end
        return dir2config[dir] = config
    end

    for path in paths
        already_formatted &= if isfile(path)
            dir = dirname(realpath(path))
            opts = if (config = find_config_file(dir)) !== nothing
                overwrite_options(options, config)
            else
                options
            end
            format_file(path; opts...)
        else
            reduce(walkdir(path), init = true) do formatted_path, dir_branch
                root, dirs, files = dir_branch
                formatted_path & reduce(files, init = true) do formatted_file, file
                    _, ext = splitext(file)
                    full_path = joinpath(root, file)
                    formatted_file &
                    if ext in (".jl", ".md") && !(".git" in splitpath(full_path))
                        dir = realpath(root)
                        opts = if (config = find_config_file(dir)) !== nothing
                            overwrite_options(options, config)
                        else
                            options
                        end
                        format_file(full_path; opts...)
                    else
                        true
                    end
                end
            end
        end
    end
    return already_formatted
end
format(path::AbstractString; options...) = format((path,); options...)

"""
    format(path, style::AbstractStyle; options...)::Bool
"""
format(path, style::AbstractStyle; options...) = format(path; style = style, options...)

"""
    format(mod::Module, args...; options...)
"""
format(mod::Module, args...; options...) = format(pkgdir(mod), args...; options...)

function kwargs(dict)
    ns = (Symbol.(keys(dict))...,)
    vs = (collect(values(dict))...,)
    return pairs(NamedTuple{ns}(vs))
end

function parse_config(tomlfile)
    config_dict = parsefile(tomlfile)
    if (style = get(config_dict, "style", nothing)) !== nothing
        @assert (style == "default" || style == "yas" || style == "blue") "currently $(CONFIG_FILE_NAME) accepts only \"default\" or \"yas\" or \"blue\" for the style configuration"
        config_dict["style"] = if (style == "yas" && @isdefined(YASStyle))
            YASStyle()
        elseif (style == "blue" && @isdefined(BlueStyle))
            BlueStyle()
        else
            DefaultStyle()
        end
    end
    return kwargs(config_dict)
end

overwrite_options(options, config) = kwargs(merge(options, config))

end
