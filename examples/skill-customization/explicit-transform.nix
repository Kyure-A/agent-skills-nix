programs.agent-skills.skills.explicit = {
  my-skill = {
    from = "my-source";
    path = "some-skill";
    packages = [ pkgs.jq pkgs.curl ]; # Symlinked into skill directory
    transform = { original, dependencies }: ''
      # Custom Header

      ${dependencies}

      ${original}

      # See Also
      - https://example.com
    '';
  };
};
