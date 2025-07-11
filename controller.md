# Kubernetes Controller 分片框架设计文档

## 1. 概述

### 1.1 设计目标
设计一个基于Go语言的Kubernetes Controller分片框架，实现：
- 基于client-go informer的分布式控制器
- 支持动态节点扩缩容时的分片重新分配
- 抽象分片算法接口，支持业务方自定义分片策略
- 提供上层对象通知机制，确保分片变化时的状态同步

### 1.2 核心特性
- **水平扩展性**: 支持多节点部署，自动分片工作负载
- **高可用性**: 节点故障时自动重新分片
- **一致性保证**: 确保资源不被重复处理或遗漏
- **可观测性**: 提供完整的分片状态监控和日志
- **可扩展性**: 插件化的分片算法和业务逻辑

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Sharded Controller Framework              │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │ Controller  │  │ Controller  │  │ Controller  │          │
│  │ Instance 1  │  │ Instance 2  │  │ Instance N  │          │
│  └─────────────┘  └─────────────┘  └─────────────┘          │
├─────────────────────────────────────────────────────────────┤
│                    Sharding Manager                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │ Sharding    │  │ Node        │  │ Rebalancing │          │
│  │ Algorithm   │  │ Manager     │  │ Manager     │          │
│  └─────────────┘  └─────────────┘  └─────────────┘          │
├─────────────────────────────────────────────────────────────┤
│                    State Manager                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │ Lease       │  │ Leader      │  │ State       │          │
│  │ Manager     │  │ Election    │  │ Synchronizer│          │
│  └─────────────┘  └─────────────┘  └─────────────┘          │
├─────────────────────────────────────────────────────────────┤
│                    Client-Go Integration                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │ Informer    │  │ Workqueue   │  │ Event       │          │
│  │ Factory     │  │ Manager     │  │ Handler     │          │
│  └─────────────┘  └─────────────┘  └─────────────┘          │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 核心组件

#### 2.2.1 Sharding Manager
- **职责**: 管理分片算法、节点状态、重新分片逻辑
- **功能**: 
  - 分片算法接口抽象
  - 节点生命周期管理
  - 分片重新平衡
  - 一致性哈希实现

#### 2.2.2 State Manager
- **职责**: 管理控制器状态、租约、领导者选举
- **功能**:
  - Lease管理（基于Kubernetes Lease API）
  - 领导者选举
  - 状态同步和持久化

#### 2.2.3 Controller Instance
- **职责**: 具体的业务控制器实现
- **功能**:
  - 资源监听和处理
  - 分片过滤
  - 业务逻辑执行

## 3. 详细设计

### 3.1 分片算法接口

```go
// ShardingAlgorithm 分片算法接口
type ShardingAlgorithm interface {
    // GetShard 根据资源标识获取分片ID
    GetShard(resourceKey string, totalShards int) int
    
    // GetShardForNode 获取节点负责的分片列表
    GetShardForNode(nodeID string, totalShards int) []int
    
    // Rebalance 重新平衡分片分配
    Rebalance(nodes []string, totalShards int) map[string][]int
    
    // ValidateShard 验证分片分配的有效性
    ValidateShard(shardID int, resourceKey string) bool
}

// 内置分片算法实现
type HashShardingAlgorithm struct{}
type ConsistentHashShardingAlgorithm struct{}
type RangeShardingAlgorithm struct{}
```

### 3.2 节点管理器

```go
// NodeManager 节点管理器
type NodeManager struct {
    // 当前节点信息
    currentNode *NodeInfo
    
    // 集群节点列表
    clusterNodes map[string]*NodeInfo
    
    // 节点状态监听器
    nodeWatchers []NodeWatcher
    
    // 分片分配状态
    shardAssignment map[string][]int
    
    // 互斥锁
    mu sync.RWMutex
}

// NodeInfo 节点信息
type NodeInfo struct {
    ID        string
    Name      string
    Address   string
    Status    NodeStatus
    Shards    []int
    LastSeen  time.Time
}

// NodeStatus 节点状态
type NodeStatus string

const (
    NodeStatusHealthy   NodeStatus = "Healthy"
    NodeStatusUnhealthy NodeStatus = "Unhealthy"
    NodeStatusLeaving   NodeStatus = "Leaving"
    NodeStatusJoining   NodeStatus = "Joining"
)
```

### 3.3 分片管理器

```go
// ShardingManager 分片管理器
type ShardingManager struct {
    // 分片算法
    algorithm ShardingAlgorithm
    
    // 节点管理器
    nodeManager *NodeManager
    
    // 当前分片分配
    currentShards map[int]string
    
    // 分片变化通知器
    shardChangeNotifiers []ShardChangeNotifier
    
    // 重新分片锁
    rebalancingMu sync.Mutex
}

// ShardChangeNotifier 分片变化通知接口
type ShardChangeNotifier interface {
    // OnShardGained 获得新分片时的回调
    OnShardGained(shardID int, resources []string)
    
    // OnShardLost 失去分片时的回调
    OnShardLost(shardID int, resources []string)
    
    // OnShardReassigned 分片重新分配时的回调
    OnShardReassigned(shardID int, oldNode, newNode string)
}
```

### 3.4 状态管理器

```go
// StateManager 状态管理器
type StateManager struct {
    // Kubernetes客户端
    kubeClient kubernetes.Interface
    
    // Lease客户端
    leaseClient coordinationv1.LeaseInterface
    
    // 当前租约
    currentLease *coordinationv1.Lease
    
    // 领导者选举
    leaderElection *leaderelection.LeaderElector
    
    // 状态存储
    stateStore StateStore
}

// StateStore 状态存储接口
type StateStore interface {
    // SaveState 保存状态
    SaveState(key string, state interface{}) error
    
    // LoadState 加载状态
    LoadState(key string, state interface{}) error
    
    // DeleteState 删除状态
    DeleteState(key string) error
    
    // ListStates 列出所有状态
    ListStates(prefix string) ([]string, error)
}
```

### 3.5 控制器框架

```go
// ShardedController 分片控制器框架
type ShardedController struct {
    // 控制器名称
    name string
    
    // 分片管理器
    shardingManager *ShardingManager
    
    // 状态管理器
    stateManager *StateManager
    
    // 资源处理器
    resourceHandler ResourceHandler
    
    // 工作队列
    workQueue workqueue.RateLimitingInterface
    
    // Informer工厂
    informerFactory informers.SharedInformerFactory
    
    // 停止信号
    stopCh chan struct{}
    
    // 等待组
    wg sync.WaitGroup
}

// ResourceHandler 资源处理器接口
type ResourceHandler interface {
    // HandleAdd 处理资源添加
    HandleAdd(obj interface{}) error
    
    // HandleUpdate 处理资源更新
    HandleUpdate(oldObj, newObj interface{}) error
    
    // HandleDelete 处理资源删除
    HandleDelete(obj interface{}) error
    
    // ShouldProcess 判断是否应该处理该资源
    ShouldProcess(obj interface{}) bool
    
    // GetResourceKey 获取资源键
    GetResourceKey(obj interface{}) string
}
```

## 4. 实现细节

### 4.1 分片算法实现

#### 4.1.1 一致性哈希算法
```go
type ConsistentHashShardingAlgorithm struct {
    hashRing *consistenthash.Ring
    virtualNodes int
}

func (c *ConsistentHashShardingAlgorithm) GetShard(resourceKey string, totalShards int) int {
    hash := c.hashRing.Get(resourceKey)
    return int(hash % uint32(totalShards))
}

func (c *ConsistentHashShardingAlgorithm) Rebalance(nodes []string, totalShards int) map[string][]int {
    // 重建哈希环
    c.hashRing = consistenthash.New(c.virtualNodes, nil)
    for _, node := range nodes {
        c.hashRing.Add(node)
    }
    
    // 重新分配分片
    assignment := make(map[string][]int)
    for i := 0; i < totalShards; i++ {
        node := c.hashRing.Get(fmt.Sprintf("shard-%d", i))
        assignment[node] = append(assignment[node], i)
    }
    
    return assignment
}
```

#### 4.1.2 范围分片算法
```go
type RangeShardingAlgorithm struct {
    ranges []ShardRange
}

type ShardRange struct {
    Start string
    End   string
    Shard int
}

func (r *RangeShardingAlgorithm) GetShard(resourceKey string, totalShards int) int {
    for _, shardRange := range r.ranges {
        if resourceKey >= shardRange.Start && resourceKey <= shardRange.End {
            return shardRange.Shard
        }
    }
    return 0 // 默认分片
}
```

### 4.2 节点发现和健康检查

```go
// NodeDiscovery 节点发现
type NodeDiscovery struct {
    kubeClient kubernetes.Interface
    nodeManager *NodeManager
    healthChecker *HealthChecker
}

func (nd *NodeDiscovery) Start() {
    // 监听节点变化
    nodeInformer := nd.kubeClient.CoreV1().Nodes().Informer()
    nodeInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    nd.onNodeAdded,
        UpdateFunc: nd.onNodeUpdated,
        DeleteFunc: nd.onNodeDeleted,
    })
    
    // 启动健康检查
    go nd.healthChecker.Start()
}

func (nd *NodeDiscovery) onNodeAdded(obj interface{}) {
    node := obj.(*corev1.Node)
    nd.nodeManager.AddNode(&NodeInfo{
        ID:   string(node.UID),
        Name: node.Name,
        Status: NodeStatusJoining,
    })
}
```

### 4.3 重新分片机制

```go
// RebalancingManager 重新分片管理器
type RebalancingManager struct {
    shardingManager *ShardingManager
    nodeManager     *NodeManager
    stateManager    *StateManager
    
    // 重新分片阈值
    rebalanceThreshold float64
    
    // 重新分片间隔
    rebalanceInterval time.Duration
}

func (rm *RebalancingManager) Start() {
    ticker := time.NewTicker(rm.rebalanceInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            rm.checkAndRebalance()
        }
    }
}

func (rm *RebalancingManager) checkAndRebalance() {
    // 检查是否需要重新分片
    if !rm.needsRebalancing() {
        return
    }
    
    // 获取当前节点列表
    nodes := rm.nodeManager.GetHealthyNodes()
    
    // 执行重新分片
    newAssignment := rm.shardingManager.algorithm.Rebalance(
        rm.getNodeIDs(nodes), 
        rm.shardingManager.GetTotalShards(),
    )
    
    // 计算分片变化
    changes := rm.calculateShardChanges(newAssignment)
    
    // 通知分片变化
    rm.notifyShardChanges(changes)
    
    // 更新分片分配
    rm.shardingManager.UpdateShardAssignment(newAssignment)
}
```

### 4.4 状态同步

```go
// StateSynchronizer 状态同步器
type StateSynchronizer struct {
    stateStore StateStore
    shardingManager *ShardingManager
    syncInterval time.Duration
}

func (ss *StateSynchronizer) Start() {
    ticker := time.NewTicker(ss.syncInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            ss.syncState()
        }
    }
}

func (ss *StateSynchronizer) syncState() {
    // 保存当前分片状态
    state := &ShardState{
        Assignment: ss.shardingManager.GetShardAssignment(),
        Timestamp:  time.Now(),
        Version:    ss.shardingManager.GetVersion(),
    }
    
    err := ss.stateStore.SaveState("shard-state", state)
    if err != nil {
        log.Errorf("Failed to save shard state: %v", err)
    }
}
```

## 5. 使用示例

### 5.1 基本使用

```go
// 创建分片控制器
func NewMyShardedController(kubeClient kubernetes.Interface) *ShardedController {
    // 创建分片算法
    algorithm := &ConsistentHashShardingAlgorithm{
        virtualNodes: 150,
    }
    
    // 创建分片管理器
    shardingManager := NewShardingManager(algorithm)
    
    // 创建状态管理器
    stateManager := NewStateManager(kubeClient)
    
    // 创建资源处理器
    resourceHandler := &MyResourceHandler{}
    
    // 创建控制器
    controller := &ShardedController{
        name:             "my-sharded-controller",
        shardingManager:  shardingManager,
        stateManager:     stateManager,
        resourceHandler:  resourceHandler,
        workQueue:        workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter()),
        informerFactory:  informers.NewSharedInformerFactory(kubeClient, time.Minute*10),
    }
    
    return controller
}

// 实现资源处理器
type MyResourceHandler struct{}

func (h *MyResourceHandler) HandleAdd(obj interface{}) error {
    pod := obj.(*corev1.Pod)
    log.Infof("Processing pod add: %s", pod.Name)
    // 实现具体的业务逻辑
    return nil
}

func (h *MyResourceHandler) ShouldProcess(obj interface{}) bool {
    pod := obj.(*corev1.Pod)
    // 根据分片规则判断是否处理
    return true
}

func (h *MyResourceHandler) GetResourceKey(obj interface{}) string {
    pod := obj.(*corev1.Pod)
    return fmt.Sprintf("%s/%s", pod.Namespace, pod.Name)
}
```

### 5.2 自定义分片算法

```go
// 自定义分片算法
type CustomShardingAlgorithm struct {
    // 自定义配置
    config map[string]interface{}
}

func (c *CustomShardingAlgorithm) GetShard(resourceKey string, totalShards int) int {
    // 实现自定义分片逻辑
    hash := fnv.New32a()
    hash.Write([]byte(resourceKey))
    return int(hash.Sum32() % uint32(totalShards))
}

func (c *CustomShardingAlgorithm) Rebalance(nodes []string, totalShards int) map[string][]int {
    // 实现自定义重新分片逻辑
    assignment := make(map[string][]int)
    
    // 平均分配分片
    shardsPerNode := totalShards / len(nodes)
    remainder := totalShards % len(nodes)
    
    shardIndex := 0
    for i, node := range nodes {
        shardCount := shardsPerNode
        if i < remainder {
            shardCount++
        }
        
        for j := 0; j < shardCount; j++ {
            assignment[node] = append(assignment[node], shardIndex)
            shardIndex++
        }
    }
    
    return assignment
}
```

## 6. 监控和可观测性

### 6.1 指标定义

```go
// Metrics 指标定义
type Metrics struct {
    // 分片相关指标
    ShardCount        prometheus.Gauge
    ShardRebalances   prometheus.Counter
    ShardChanges      prometheus.Counter
    
    // 节点相关指标
    NodeCount         prometheus.Gauge
    NodeHealth        prometheus.Gauge
    
    // 处理相关指标
    ProcessedResources prometheus.Counter
    ProcessingLatency  prometheus.Histogram
    ProcessingErrors   prometheus.Counter
}

// 注册指标
func RegisterMetrics(registry prometheus.Registerer) *Metrics {
    metrics := &Metrics{
        ShardCount: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "sharded_controller_shard_count",
            Help: "Number of shards",
        }),
        ShardRebalances: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "sharded_controller_rebalances_total",
            Help: "Total number of shard rebalances",
        }),
        // ... 其他指标
    }
    
    registry.MustRegister(
        metrics.ShardCount,
        metrics.ShardRebalances,
        // ... 其他指标
    )
    
    return metrics
}
```

### 6.2 日志规范

```go
// 结构化日志
type ControllerLogger struct {
    logger *zap.Logger
}

func (cl *ControllerLogger) LogShardChange(oldShards, newShards map[int]string) {
    cl.logger.Info("Shard assignment changed",
        zap.Any("old_assignment", oldShards),
        zap.Any("new_assignment", newShards),
        zap.Time("timestamp", time.Now()),
    )
}

func (cl *ControllerLogger) LogNodeHealth(nodeID string, status NodeStatus) {
    cl.logger.Info("Node health status changed",
        zap.String("node_id", nodeID),
        zap.String("status", string(status)),
        zap.Time("timestamp", time.Now()),
    )
}
```

## 7. 部署和配置

### 7.1 配置文件

```yaml
# config.yaml
sharding:
  algorithm: "consistent-hash"
  virtualNodes: 150
  rebalanceThreshold: 0.1
  rebalanceInterval: "30s"

node:
  healthCheckInterval: "10s"
  healthCheckTimeout: "5s"
  nodeTimeout: "60s"

state:
  syncInterval: "10s"
  leaseDuration: "15s"
  renewDeadline: "10s"
  retryPeriod: "2s"

metrics:
  enabled: true
  port: 8080
  path: "/metrics"

logging:
  level: "info"
  format: "json"
```

### 7.2 部署清单

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sharded-controller
spec:
  replicas: 3
  selector:
    matchLabels:
      app: sharded-controller
  template:
    metadata:
      labels:
        app: sharded-controller
    spec:
      containers:
      - name: controller
        image: my-sharded-controller:latest
        ports:
        - containerPort: 8080
        env:
        - name: CONFIG_FILE
          value: "/etc/config/config.yaml"
        volumeMounts:
        - name: config
          mountPath: /etc/config
      volumes:
      - name: config
        configMap:
          name: sharded-controller-config
---
apiVersion: v1
kind: Service
metadata:
  name: sharded-controller-metrics
spec:
  selector:
    app: sharded-controller
  ports:
  - port: 8080
    targetPort: 8080
```

## 8. 测试策略

### 8.1 单元测试

```go
func TestShardingAlgorithm(t *testing.T) {
    algorithm := &ConsistentHashShardingAlgorithm{virtualNodes: 150}
    
    // 测试分片分配
    shard := algorithm.GetShard("test-resource", 10)
    assert.True(t, shard >= 0 && shard < 10)
    
    // 测试重新分片
    nodes := []string{"node1", "node2", "node3"}
    assignment := algorithm.Rebalance(nodes, 10)
    assert.Len(t, assignment, 3)
}
```

### 8.2 集成测试

```go
func TestShardedControllerIntegration(t *testing.T) {
    // 创建测试环境
    testEnv := &testenv.Environment{}
    defer testEnv.Cleanup()
    
    // 创建控制器
    controller := NewMyShardedController(testEnv.Client)
    
    // 启动控制器
    go controller.Start()
    defer controller.Stop()
    
    // 创建测试资源
    pod := createTestPod("test-pod")
    testEnv.Create(pod)
    
    // 验证处理结果
    assert.Eventually(t, func() bool {
        return controller.IsProcessed(pod.Name)
    }, time.Second*10, time.Millisecond*100)
}
```

## 9. 性能考虑

### 9.1 性能优化

1. **批量处理**: 支持批量处理资源变更
2. **缓存优化**: 使用本地缓存减少API调用
3. **并发控制**: 合理控制并发数量
4. **内存管理**: 及时释放不需要的资源

### 9.2 扩展性设计

1. **水平扩展**: 支持动态增加节点
2. **垂直扩展**: 支持增加单个节点的处理能力
3. **分片粒度**: 支持调整分片粒度

## 10. 安全考虑

### 10.1 访问控制

1. **RBAC**: 使用Kubernetes RBAC控制权限
2. **认证**: 支持多种认证方式
3. **审计**: 记录所有操作日志

### 10.2 数据安全

1. **加密**: 敏感数据加密存储
2. **传输安全**: 使用TLS加密传输
3. **访问限制**: 限制对敏感资源的访问

## 11. 故障处理

### 11.1 故障检测

1. **健康检查**: 定期检查节点健康状态
2. **超时处理**: 设置合理的超时时间
3. **重试机制**: 实现指数退避重试

### 11.2 故障恢复

1. **自动恢复**: 自动处理临时故障
2. **手动干预**: 提供手动恢复工具
3. **回滚机制**: 支持配置回滚

## 12. 总结

这个分片框架设计提供了：

1. **完整的抽象**: 通过接口抽象分片算法和业务逻辑
2. **高可用性**: 支持节点故障自动恢复
3. **可扩展性**: 支持动态扩缩容
4. **可观测性**: 提供完整的监控和日志
5. **易用性**: 提供简单的API和配置

通过这个框架，业务方可以专注于实现具体的业务逻辑，而分片、节点管理、状态同步等复杂问题都由框架统一处理。 
