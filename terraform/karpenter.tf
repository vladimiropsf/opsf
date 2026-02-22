locals {
  node_pools = {
    x86 = {
      arch       = "amd64"
      min_gen    = "3"
      extra_taints = []
    }
    arm64 = {
      arch       = "arm64"
      min_gen    = "5"
      extra_taints = [{
        key    = "kubernetes.io/arch"
        value  = "arm64"
        effect = "NoSchedule"
      }]
    }
  }
}

resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version

  values = [yamlencode({
    replicas     = 1
    nodeSelector = { "karpenter.sh/controller" = "true" }
    settings = {
      clusterEndpoint   = module.eks.cluster_endpoint
      clusterName       = module.eks.cluster_name
      interruptionQueue = module.karpenter.queue_name
    }
  })]

  depends_on = [module.eks, module.karpenter]
}

# Shared node class - works for both architectures since AL2023 AMI alias
# resolves to the correct arch based on the node pool requirements
resource "kubectl_manifest" "node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      instanceProfile: ${module.karpenter.instance_profile_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      amiSelectorTerms:
        - alias: al2023@latest
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 50Gi
            volumeType: gp3
            encrypted: true
            deleteOnTermination: true
      metadataOptions:
        httpEndpoint: enabled
        httpPutResponseHopLimit: 2
        httpTokens: required
      tags:
        Environment: ${var.environment}
        ManagedBy: karpenter
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "node_pool" {
  for_each = local.node_pools

  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: spot-${each.key}
    spec:
      template:
        metadata:
          labels:
            node-type: spot-${each.key}
        spec:
          requirements:
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot"]
            - key: kubernetes.io/arch
              operator: In
              values: ["${each.value.arch}"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["t"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["${each.value.min_gen}"]
            - key: karpenter.k8s.aws/instance-size
              operator: In
              values: ["micro", "small"]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          taints:
            - key: karpenter.sh/spot
              value: "true"
              effect: NoSchedule
%{for t in each.value.extra_taints~}
            - key: ${t.key}
              value: ${t.value}
              effect: ${t.effect}
%{endfor~}
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 30s
      limits:
        cpu: 1000
        memory: 1000Gi
  YAML

  depends_on = [kubectl_manifest.node_class]
}