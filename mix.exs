defmodule SpandexNewrelic.MixProject do
  use Mix.Project
  @version "1.0.0"
  def project do
    [
      app: :spandex_newrelic,
      description: description(),
      version: @version,
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SpandexNewrelic.Application, []}
    ]
  end

  defp package do
    [
      name: :spandex_newrelic,
      maintainers: ["Pedro Mangabeira"],
      licenses: ["MIT License"],
      links: %{"GitHub" => "https://github.com/MaethorNaur/spandex_newrelic"}
    ]
  end

  defp description do
    """
    A Newrelic API adapter for spandex.
    """
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md"
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:uuid,"~> 1.1"},
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:inch_ex, "~> 2.0", only: [:dev, :test]},
      {:spandex, "~> 3.0"},
      {:mojito, "~> 0.7.3"},
      {:jason, "~> 1.2"}
    ]
  end
end
