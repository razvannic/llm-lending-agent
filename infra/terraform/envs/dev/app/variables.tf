variable "env" { type = string }
variable "app_name" { type = string }
variable "aws_region" { type = string }
variable "agentcore_runtime_arn" {
  type        = string
  description = "Existing AgentCore runtime ARN (created outside this module)"
}
