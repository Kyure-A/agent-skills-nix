{ ... }:
{
  home.username = "example";
  home.homeDirectory = "/home/example";
  home.stateVersion = "24.05";

  programs.agent-skills = {
    enable = true;
    sources.anthropic = {
      input = "anthropic-skills";
      subdir = "skills";
    };
    skills.enable = [ "frontend-design" "skill-creator" ];
  };
}
