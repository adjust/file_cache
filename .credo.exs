%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/"],
        excluded: []
      },
      strict: true,
      checks: [
        {Credo.Check.Warning.RaiseInsideRescue, false},
        {Credo.Check.Readability.WithSingleClause, false},
        {Credo.Check.Design.TagTODO, false},
        {Credo.Check.Design.TagFIXME, false},
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Refactor.Apply, false}
      ]
    }
  ]
}
