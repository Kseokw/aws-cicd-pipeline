# ################################################################################
# Terraform Block 
# ================================================================================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>6.0" # 6.0~<7.0
    }
  }
}

# ################################################################################
# Provider Block
# ================================================================================
provider "aws" {
  region = "ap-southeast-1" # AWS 리전 설정
  default_tags {            # 모든 리소스에 공통 태그 적용
    tags = {
      Class = "bipa17"
      Owner = "std07"
    }
  }
}

# ################################################################################
# 테라폼 기본 설정
# ================================================================================
variable "key_name" {
  description = "키페어 이름"
  type        = string
  default     = "std07-key"
}
variable "owner" {
  description = "기본 태그 이름"
  type        = string
  default     = "std07"
}
variable "environment" {
  description = "프로젝트 역할 구분"
  type        = string
  default     = "ex" # dev / db / op / ex/ lab /
}
variable "default_version" {
  description = "시작템플릿 기본 버전 지정"
  type        = string
  default     = "latest" # 특정 버전을 지정하고자 할 경우 문자열 형태의 숫자 기재
}
variable "asg_subnet_type" {
  description = "오토스케일그룹이 사용할 서브넷 그룹"
  type        = string
  default     = "Cluster"
}

locals {
  key_name = var.key_name
  tag_header = (var.owner != "" && var.environment != "") ? "${var.owner}-${var.environment}" : (
    (var.owner != "") ? "${var.owner}" : ""
  )
  #   tag_header         = var.owner
  vpc_id             = data.aws_vpc.vpc.id
  ami_id             = data.aws_ami.al2023.id
  security_group_ids = data.aws_security_groups.security_groups.ids
  #   vpc_security_group_id = [
  #     data.aws_security_group.security_groups_alb.id,
  #   data.aws_security_group.security_groups_ssh.id]
  ec2_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]
  asg_subnet_types = data.aws_subnets.target_subnets.ids
}


# vpc ID
data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["${var.owner}-network-vpc"]
  }
}


# Amazon Linux 2023 최신 AMI 조회
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# 인스턴스에 추가할 보안 그룹
data "aws_security_groups" "security_groups" {
  filter {
    name = "tag:Name"
    values = [
      "${var.owner}-external-alb-sg",
      "${var.owner}-internal-ssh-sg"
    ]
  }
}

# data "aws_security_group" "security_groups_alb" {
#   filter {
#     name   = "tag:Name"
#     values = ["${local.tag_header}-external-alb-sg"]
#   }
# }
# data "aws_security_group" "security_groups_ssh" {
#   filter {
#     name   = "tag:Name"
#     values = ["${local.tag_header}-internal-ssh-sg"]
#   }
# }


data "aws_subnets" "target_subnets" {
  filter {
    name   = "tag:Type"
    values = [var.asg_subnet_type]
  }
}

output "information" {
  value = [
    local.vpc_id,
    local.security_group_ids,
    # local.vpc_security_group_id
  ]
}

# ======================================================================
# 인스턴스에 부여할 역할
# ======================================================================
resource "aws_iam_role" "node_role_asg" {
  name = "${local.tag_header}-AmazonASGNodeEC2-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole" # 신뢰관계 허용(IAM Role을 임시로 획득하여 권한을 행사, 임시권한)
    }]
  })
}

# 정책 연결
resource "aws_iam_role_policy_attachment" "node_policies_asg" {
  for_each   = toset(local.ec2_policy_arns)
  role       = aws_iam_role.node_role_asg.name
  policy_arn = each.value
}

# 인스턴스 프로필 생성
resource "aws_iam_instance_profile" "node_profile_asg" {
  name = "${local.tag_header}-ASGNodeInstance-profile"
  role = aws_iam_role.node_role_asg.name
}

# ================================================================================
# CodeDeploy 역할(Role)
# --------------------------------------------------------------------------------
# 역할 생성
resource "aws_iam_role" "codedeploy_role" {
  name = "${local.tag_header}-AmazonCodeDeployService-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codedeploy.amazonaws.com" }
      Action    = "sts:AssumeRole" # IAM Role을 임시로 획득하여 권한을 행사할 수 있도록 허용
    }]
  })
}

# 관리형 정책을 역할에 연결
resource "aws_iam_role_policy_attachment" "codedeploy_policy" {
  role       = aws_iam_role.codedeploy_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}


# ================================================================================
# CodePipeline 서비스 IAM Role
# --------------------------------------------------------------------------------
resource "aws_iam_role" "codepipeline_role" {
  name = "${local.tag_header}-AmazonCodePipelineService-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole" # IAM Role을 임시로 획득하여 권한을 행사할 수 있도록 허용
    }]
  })
}

# 각 서비스에 대한 접근 권한(정책) 생성
resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "${local.tag_header}-codepipelineServicePolicy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetBucketVersioning", "s3:PutObjectAcl", "s3:PutObject"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:GetDeployment",
          "codedeploy:GetDeploymentConfig",
          "codedeploy:RegisterApplicationRevision",
          "codestar-connections:UseConnection"
        ]
        Resource = "*"
      }
    ]
  })
}


# ======================================================================
# Pipeline Artifacts 저장용 S3 Bucket
# ======================================================================
#
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# pipeline 구성에 필요한 배포 파일 저장소 생성
resource "aws_s3_bucket" "pipeline_bucket" {
  bucket        = "${local.tag_header}-pipeline-bucket-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${local.tag_header}-pipeline-bucket-${random_id.bucket_suffix.hex}"
  }
}

# 생성된 버킷의 버전관리 활성화(Codepipline에서 필수 요구사항)
resource "aws_s3_bucket_versioning" "pipeline_bucket_versioning" {
  bucket = aws_s3_bucket.pipeline_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}


# 퍼블릭 액세스 전체 차단(보안 규정 준수)

resource "aws_s3_bucket_public_access_block" "pipeline_bucket_public_access" {
  bucket = aws_s3_bucket.pipeline_bucket.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# 서버 측 기본 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_bucket_encryption" {
  bucket = aws_s3_bucket.pipeline_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3 
    }
  }
}

# ======================================================================
# Launch Template & UserData
# ======================================================================
# 템플릿 생성
resource "aws_launch_template" "asg_lt" {
  name_prefix            = "${local.tag_header}-"
  image_id               = local.ami_id # data.aws_ami.al2023.id
  instance_type          = "t3.small"
  key_name               = local.key_name
  vpc_security_group_ids = local.security_group_ids


  # 기본 버전 지정 방법
  update_default_version = var.default_version == "latest" ? true : false # 기본 버전을 latest로 업데이트
  default_version        = var.default_version != "latest" ? tostring(var.default_version) : null

  iam_instance_profile {
    name = aws_iam_instance_profile.node_profile_asg.name

  }

  # user data
  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf update -y
    # ruby: CodeDeploy서비스 개발 언어, codedeploy-agent 설치를 위해 반드시 필요
    dnf install -y ruby wget docker

    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user

    cd /tmp
    wget https://aws-codedeploy-ap-southeast-1.s3.ap-southeast-1.amazonaws.com/latest/install
    chmod +x ./install
    ./install auto

    systemctl start codedeploy-agent
    systemctl enable codedeploy-agent
    EOF
  )
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.tag_header}-asg-node-instance"
    }
  }
}


# ======================================================================
# Auto Scaling Group
# ======================================================================
resource "aws_autoscaling_group" "asg" {
  name                = "${local.tag_header}-codedeploy-asg"
  min_size            = 1
  max_size            = 3
  desired_capacity    = 2
  vpc_zone_identifier = local.asg_subnet_types

  launch_template {
    id      = aws_launch_template.asg_lt.id
    version = "$Latest"
  }
}

# ======================================================================
# CodeDeploy Application & Deployment Group
# ======================================================================
resource "aws_codedeploy_app" "app" {
  name = "${local.tag_header}-asg-codedeploy-app"
  # 배포 대상 정의: Server / Lambda / ECS
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "dg" {
  deployment_group_name = "${local.tag_header}-asg-deployment-group"
  # codedeploy_app 리소스 이름
  app_name = aws_codedeploy_app.app.name
  # codedeploy 서비스에 추가해줄 역할(Role)
  service_role_arn = aws_iam_role.codedeploy_role.arn

  autoscaling_groups = [aws_autoscaling_group.asg.name]
  # 배포 대상 정의
  # "CodeDeployDefault.AllAtOnce": 타겟 인스턴스 전체에 동시에 한 번에 배포하는 방식
  #                                전체 중당 -> 동시 배포 -> 동시 재시작
  # "OneAtTime": 한 대씩 순차 배포(1대 배포 -> 검증 및 다음 배포 대상 진행 -> 순차 반복)
  # "HalfAtTime": 대상 인스턴의의 50%를 먼저 배포 후 나머지 배포

  deployment_config_name = "CodeDeployDefault.AllAtOnce"
}


# ======================================================================
# 연결 리소스 생성 및 CodePipeline 리소스 생성
# ======================================================================
# AWS - GitHub 간 CodeStar Connection 생성
resource "aws_codestarconnections_connection" "github" {
  name          = "${local.tag_header}-github-connection"
  provider_type = "GitHub"
}

# ======================================================================
# AWS CodePipeline 생성
# ======================================================================
resource "aws_codepipeline" "codepipeline" {
  name = "${local.tag_header}-asg-cicd-pipeline"

  # CodePipeline Role 정의
  role_arn = aws_iam_role.codepipeline_role.arn

  # 소스코드 정보
  artifact_store {
    # 앞서 생성한 Pipeline 전용 s3 버킷 이름 지정
    location = aws_s3_bucket.pipeline_bucket.bucket

    # 아티팩트 저장소 유형 지정 (S3 사용)
    type = "S3"
  }

  # Stage 1: Source
  stage {
    name = "Source"
    action {
      name     = "Source"
      category = "Source"
      owner    = "AWS"                      # 액션 제공자(AWS에서 제공하는 서비스 활용)
      provider = "CodeStarSourceConnection" # GitHub V2 액션과연동 표준인 "CodeStarSourceConnection" 사용
      version  = "1"
      # ZIP 소스 압축파일을 다음 스테이지로 전달할 때 사용할 아티팩트 이름 선언
      output_artifacts = ["source_output"]

      # GitHub 연동을 위한 속성값 정의
      configuration = {
        # GitHub와 CodeDeploy를 연결하는 연결 객체 정의
        ConnectionArn = aws_codestarconnections_connection.github.arn
        # GitHub Repository 이름
        FullRepositoryId = "Kseokw/aws-cicd-pipeline"
        # 브랜치 정의
        BranchName = "main"

      }
    }
  }

  # Stage 2: Deploy
  stage {
    name = "Deploy"
    action {
      name     = "Deploy"
      category = "Deploy"
      owner    = "AWS"        # 액션 제공자(AWS에서 제공하는 서비스 활용)
      provider = "CodeDeploy" # 배포에 사용할 AWS 서비스지정 (CodeDeploy)
      version  = "1"
      # ZIP 소스 압축파일을 다음 스테이지로 전달할 때 사용할 아티팩트 이름 선언
      input_artifacts = ["source_output"] # stage1의 output에 정의된 이름

      # GitHub 연동을 위한 속성값 정의
      configuration = {
        # 배포서비스(CodeDeploy Application) 이름
        ApplicationName     = aws_codedeploy_app.app.name
        DeploymentGroupName = aws_codedeploy_deployment_group.dg.deployment_group_name
      }
    }
  }
}
