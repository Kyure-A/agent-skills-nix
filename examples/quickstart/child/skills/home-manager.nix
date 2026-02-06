{ anthropic-skills, ... }:
{
  programs.agent-skills = {
    sources.anthropic = {
      path = anthropic-skills;
      subdir = "skills";
    };
    skills.enable = [ "frontend-design" "skill-creator" ];
    targets.claude.enable = true;
  };
}
