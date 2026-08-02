{
  pin = {
    type = "git";
    url = "https://example.invalid/alpha.git";
    branch = "main; touch PWNED";
    forge = "none";
  };

  subdir = ".";
  idPrefix = "fixture";
  filter.maxDepth = 3;
}
