using QMCPedagogique
using Documenter

DocMeta.setdocmeta!(QMCPedagogique, :DocTestSetup, :(using QMCPedagogique); recursive=true)

makedocs(;
    modules=[QMCPedagogique],
    authors="v1j4y <vijay.gopal.c@gmail.com> and contributors",
    repo="https://github.com/v1j4y/QMCPedagogique.jl/blob/{commit}{path}#{line}",
    sitename="QMCPedagogique.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://v1j4y.github.io/QMCPedagogique.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/v1j4y/QMCPedagogique.jl",
)
