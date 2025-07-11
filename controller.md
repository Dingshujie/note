# Kubernetes Controller 分片框架设计文档

## 1. 概述

### 1.1 设计目标
设计一个基于Go语言的Kubernetes Controller分片框架，实现：
- 基于client-go informer的分布式控制器
- 支持动态controller实例扩缩容时的分片重新分配
- 抽象分片算法接口，支持业务方自定义分片策略
- 提供上层对象通知机制，确保分片变化时的状态同步

### 1.2 核心特性
- **水平扩展性**: 支持多实例部署，自动分片工作负载
- **高可用性**: controller实例故障时自动重新分片
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
│  │ Sharding    │  │ Instance    │  │ Rebalancing │          │
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
- **职责**: 管理分片算法、controller实例状态、重新分片逻辑
- **功能**: 
  - 分片算法接口抽象
  - controller实例生命周期管理
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
    
    // GetShardForInstance 获取controller实例负责的分片列表
    GetShardForInstance(instanceID string, totalShards int) []int
    
    // Rebalance 重新平衡分片分配
    Rebalance(instances []string, totalShards int) map[string][]int
    
    // ValidateShard 验证分片分配的有效性
    ValidateShard(shardID int, resourceKey string) bool
}

// 内置分片算法实现
type HashShardingAlgorithm struct{}
type ConsistentHashShardingAlgorithm struct{}
type RangeShardingAlgorithm struct{}
```

### 3.2 controller实例管理器

```go
// InstanceManager controller实例管理器
type InstanceManager struct {
    // 当前实例信息
    currentInstance *ControllerInstanceInfo
    
    // 集群实例列表
    clusterInstances map[string]*ControllerInstanceInfo
    
    // 实例状态监听器
    instanceWatchers []InstanceWatcher
    
    // 分片分配状态
    shardAssignment map[string][]int
    
    // 互斥锁
    mu sync.RWMutex
}

// ControllerInstanceInfo controller实例信息
type ControllerInstanceInfo struct {
    ID        string
    Name      string
    Address   string
    Status    InstanceStatus
    Shards    []int
    LastSeen  time.Time
    PodName   string    // 对应的Pod名称
    Namespace string    // 对应的命名空间
}

// InstanceStatus controller实例状态
type InstanceStatus string

const (
    InstanceStatusHealthy   InstanceStatus = "Healthy"
    InstanceStatusUnhealthy InstanceStatus = "Unhealthy"
    InstanceStatusLeaving   InstanceStatus = "Leaving"
    InstanceStatusJoining   InstanceStatus = "Joining"
)
```

### 3.3 分片管理器

```go
// ShardingManager 分片管理器
type ShardingManager struct {
    // 分片算法
    algorithm ShardingAlgorithm
    
    // controller实例管理器
    instanceManager *InstanceManager
    
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
    OnShardReassigned(shardID int, oldInstance, newInstance string)
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

func (c *ConsistentHashShardingAlgorithm) Rebalance(instances []string, totalShards int) map[string][]int {
    // 重建哈希环
    c.hashRing = consistenthash.New(c.virtualNodes, nil)
    for _, instance := range instances {
        c.hashRing.Add(instance)
    }
    
    // 重新分配分片
    assignment := make(map[string][]int)
    for i := 0; i < totalShards; i++ {
        instance := c.hashRing.Get(fmt.Sprintf("shard-%d", i))
        assignment[instance] = append(assignment[instance], i)
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

### 4.2 Controller Instance 注册发现机制

#### 4.2.1 基于Lease的注册机制

```go
// InstanceRegistry controller实例注册器
type InstanceRegistry struct {
    kubeClient kubernetes.Interface
    leaseClient coordinationv1.LeaseInterface
    instanceManager *InstanceManager
    currentInstance *ControllerInstanceInfo
    
    // 注册配置
    leaseNamespace string
    leaseNamePrefix string
    leaseDuration time.Duration
    renewInterval time.Duration
    
    // 停止信号
    stopCh chan struct{}
    wg sync.WaitGroup
}

// LeaseInfo Lease信息
type LeaseInfo struct {
    Name      string
    Namespace string
    Holder    string
    RenewTime time.Time
    LeaseTime time.Duration
}

func (ir *InstanceRegistry) Start() error {
    // 创建当前实例的Lease
    leaseName := fmt.Sprintf("%s-%s", ir.leaseNamePrefix, ir.currentInstance.ID)
    lease := &coordinationv1.Lease{
        ObjectMeta: metav1.ObjectMeta{
            Name:      leaseName,
            Namespace: ir.leaseNamespace,
            Labels: map[string]string{
                "app": ir.currentInstance.Name,
                "instance-id": ir.currentInstance.ID,
            },
        },
        Spec: coordinationv1.LeaseSpec{
            HolderIdentity: &ir.currentInstance.ID,
            LeaseDurationSeconds: &ir.leaseDuration,
            RenewTime: &metav1.MicroTime{Time: time.Now()},
        },
    }
    
    // 创建或更新Lease
    _, err := ir.leaseClient.Create(context.Background(), lease, metav1.CreateOptions{})
    if err != nil && !errors.IsAlreadyExists(err) {
        return fmt.Errorf("failed to create lease: %v", err)
    }
    
    // 启动Lease续期
    ir.wg.Add(1)
    go ir.renewLease(leaseName)
    
    // 启动实例发现
    ir.wg.Add(1)
    go ir.discoverInstances()
    
    return nil
}

func (ir *InstanceRegistry) renewLease(leaseName string) {
    defer ir.wg.Done()
    
    ticker := time.NewTicker(ir.renewInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            if err := ir.updateLease(leaseName); err != nil {
                log.Errorf("Failed to renew lease: %v", err)
            }
        case <-ir.stopCh:
            return
        }
    }
}

func (ir *InstanceRegistry) updateLease(leaseName string) error {
    lease, err := ir.leaseClient.Get(context.Background(), leaseName, metav1.GetOptions{})
    if err != nil {
        return err
    }
    
    now := metav1.MicroTime{Time: time.Now()}
    lease.Spec.RenewTime = &now
    
    _, err = ir.leaseClient.Update(context.Background(), lease, metav1.UpdateOptions{})
    return err
}

func (ir *InstanceRegistry) discoverInstances() {
    defer ir.wg.Done()
    
    // 监听Lease变化
    leaseInformer := ir.leaseClient.Informer()
    leaseInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    ir.onLeaseAdded,
        UpdateFunc: ir.onLeaseUpdated,
        DeleteFunc: ir.onLeaseDeleted,
    })
    
    // 启动informer
    leaseInformer.Run(ir.stopCh)
}

func (ir *InstanceRegistry) onLeaseAdded(obj interface{}) {
    lease := obj.(*coordinationv1.Lease)
    if !ir.isTargetLease(lease) {
        return
    }
    
    instanceInfo := &ControllerInstanceInfo{
        ID:        lease.Labels["instance-id"],
        Name:      lease.Labels["app"],
        Status:    InstanceStatusJoining,
        LastSeen:  time.Now(),
        PodName:   lease.Labels["pod-name"],
        Namespace: lease.Namespace,
    }
    
    ir.instanceManager.AddInstance(instanceInfo)
}

func (ir *InstanceRegistry) onLeaseUpdated(oldObj, newObj interface{}) {
    oldLease := oldObj.(*coordinationv1.Lease)
    newLease := newObj.(*coordinationv1.Lease)
    
    if !ir.isTargetLease(newLease) {
        return
    }
    
    // 检查Lease是否过期
    if ir.isLeaseExpired(newLease) {
        ir.instanceManager.UpdateInstanceStatus(
            newLease.Labels["instance-id"], 
            InstanceStatusUnhealthy,
        )
    } else {
        ir.instanceManager.UpdateInstanceStatus(
            newLease.Labels["instance-id"], 
            InstanceStatusHealthy,
        )
    }
}

func (ir *InstanceRegistry) onLeaseDeleted(obj interface{}) {
    lease := obj.(*coordinationv1.Lease)
    if !ir.isTargetLease(lease) {
        return
    }
    
    ir.instanceManager.RemoveInstance(lease.Labels["instance-id"])
}

func (ir *InstanceRegistry) isTargetLease(lease *coordinationv1.Lease) bool {
    return lease.Labels["app"] == ir.currentInstance.Name
}

func (ir *InstanceRegistry) isLeaseExpired(lease *coordinationv1.Lease) bool {
    if lease.Spec.RenewTime == nil {
        return true
    }
    
    expiryTime := lease.Spec.RenewTime.Add(time.Duration(*lease.Spec.LeaseDurationSeconds) * time.Second)
    return time.Now().After(expiryTime)
}
```

#### 4.2.2 基于ConfigMap的注册机制（备选方案）

```go
// ConfigMapRegistry 基于ConfigMap的注册器
type ConfigMapRegistry struct {
    kubeClient kubernetes.Interface
    instanceManager *InstanceManager
    currentInstance *ControllerInstanceInfo
    
    configMapName string
    namespace     string
    updateInterval time.Duration
}

func (cmr *ConfigMapRegistry) Start() error {
    // 创建或更新ConfigMap
    configMap := &corev1.ConfigMap{
        ObjectMeta: metav1.ObjectMeta{
            Name:      cmr.configMapName,
            Namespace: cmr.namespace,
        },
        Data: map[string]string{
            cmr.currentInstance.ID: cmr.serializeInstanceInfo(),
        },
    }
    
    _, err := cmr.kubeClient.CoreV1().ConfigMaps(cmr.namespace).Create(
        context.Background(), configMap, metav1.CreateOptions{},
    )
    if err != nil && !errors.IsAlreadyExists(err) {
        return err
    }
    
    // 启动定期更新
    go cmr.periodicUpdate()
    
    return nil
}

func (cmr *ConfigMapRegistry) serializeInstanceInfo() string {
    info := map[string]interface{}{
        "id":        cmr.currentInstance.ID,
        "name":      cmr.currentInstance.Name,
        "pod_name":  cmr.currentInstance.PodName,
        "namespace": cmr.currentInstance.Namespace,
        "timestamp": time.Now().Unix(),
    }
    
    data, _ := json.Marshal(info)
    return string(data)
}
```

### 4.3 Controller Instance 退出机制

#### 4.3.1 优雅退出流程

```go
// GracefulShutdown 优雅退出管理器
type GracefulShutdown struct {
    instanceRegistry *InstanceRegistry
    shardingManager  *ShardingManager
    stateManager     *StateManager
    
    // 退出配置
    shutdownTimeout time.Duration
    drainTimeout    time.Duration
    
    // 信号处理
    signalCh chan os.Signal
    stopCh   chan struct{}
}

func (gs *GracefulShutdown) Start() {
    // 监听系统信号
    gs.signalCh = make(chan os.Signal, 1)
    signal.Notify(gs.signalCh, syscall.SIGTERM, syscall.SIGINT)
    
    go gs.handleSignals()
}

func (gs *GracefulShutdown) handleSignals() {
    for {
        select {
        case sig := <-gs.signalCh:
            log.Infof("Received signal: %v, starting graceful shutdown", sig)
            gs.performGracefulShutdown()
            return
        case <-gs.stopCh:
            return
        }
    }
}

func (gs *GracefulShutdown) performGracefulShutdown() {
    ctx, cancel := context.WithTimeout(context.Background(), gs.shutdownTimeout)
    defer cancel()
    
    // 1. 标记实例为退出状态
    gs.instanceRegistry.MarkInstanceLeaving()
    
    // 2. 等待分片重新分配
    gs.waitForShardRebalancing(ctx)
    
    // 3. 停止处理新的资源
    gs.stopResourceProcessing()
    
    // 4. 等待当前任务完成
    gs.waitForCurrentTasks(ctx)
    
    // 5. 清理资源
    gs.cleanupResources()
    
    // 6. 注销实例
    gs.deregisterInstance()
    
    log.Info("Graceful shutdown completed")
}

func (gs *GracefulShutdown) waitForShardRebalancing(ctx context.Context) {
    log.Info("Waiting for shard rebalancing...")
    
    ticker := time.NewTicker(time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            log.Warn("Shard rebalancing timeout")
            return
        case <-ticker.C:
            if gs.shardingManager.IsRebalancingComplete() {
                log.Info("Shard rebalancing completed")
                return
            }
        }
    }
}

func (gs *GracefulShutdown) stopResourceProcessing() {
    log.Info("Stopping resource processing...")
    // 停止工作队列
    gs.shardingManager.StopProcessing()
}

func (gs *GracefulShutdown) waitForCurrentTasks(ctx context.Context) {
    log.Info("Waiting for current tasks to complete...")
    
    // 等待工作队列清空
    if err := gs.shardingManager.WaitForQueueEmpty(ctx); err != nil {
        log.Warnf("Timeout waiting for queue to empty: %v", err)
    }
}

func (gs *GracefulShutdown) cleanupResources() {
    log.Info("Cleaning up resources...")
    
    // 清理本地缓存
    gs.shardingManager.CleanupCache()
    
    // 清理状态
    gs.stateManager.Cleanup()
}

func (gs *GracefulShutdown) deregisterInstance() {
    log.Info("Deregistering instance...")
    
    // 删除Lease
    gs.instanceRegistry.DeleteLease()
    
    // 从ConfigMap中移除实例信息
    gs.instanceRegistry.RemoveFromConfigMap()
}
```

#### 4.3.2 实例管理器退出处理

```go
// InstanceManager 扩展退出处理
func (im *InstanceManager) MarkInstanceLeaving() {
    im.mu.Lock()
    defer im.mu.Unlock()
    
    if im.currentInstance != nil {
        im.currentInstance.Status = InstanceStatusLeaving
        im.currentInstance.LastSeen = time.Now()
    }
}

func (im *InstanceManager) WaitForShardTransfer(shardIDs []int, timeout time.Duration) error {
    ctx, cancel := context.WithTimeout(context.Background(), timeout)
    defer cancel()
    
    ticker := time.NewTicker(time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return fmt.Errorf("timeout waiting for shard transfer")
        case <-ticker.C:
            if im.areShardsTransferred(shardIDs) {
                return nil
            }
        }
    }
}

func (im *InstanceManager) areShardsTransferred(shardIDs []int) bool {
    im.mu.RLock()
    defer im.mu.RUnlock()
    
    for _, shardID := range shardIDs {
        if im.isShardAssignedToCurrentInstance(shardID) {
            return false
        }
    }
    return true
}

func (im *InstanceManager) isShardAssignedToCurrentInstance(shardID int) bool {
    if im.currentInstance == nil {
        return false
    }
    
    for _, assignedShard := range im.currentInstance.Shards {
        if assignedShard == shardID {
            return true
        }
    }
    return false
}
```

#### 4.3.3 分片管理器退出处理

```go
// ShardingManager 扩展退出处理
func (sm *ShardingManager) StopProcessing() {
    sm.mu.Lock()
    defer sm.mu.Unlock()
    
    // 标记停止处理
    sm.processingStopped = true
}

func (sm *ShardingManager) WaitForQueueEmpty(ctx context.Context) error {
    ticker := time.NewTicker(time.Millisecond * 100)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-ticker.C:
            if sm.workQueue.Len() == 0 {
                return nil
            }
        }
    }
}

func (sm *ShardingManager) IsRebalancingComplete() bool {
    sm.mu.RLock()
    defer sm.mu.RUnlock()
    
    // 检查当前实例是否还有分片
    if sm.currentInstance == nil {
        return true
    }
    
    return len(sm.currentInstance.Shards) == 0
}

func (sm *ShardingManager) CleanupCache() {
    sm.mu.Lock()
    defer sm.mu.Unlock()
    
    // 清理本地缓存
    sm.localCache.Clear()
    
    // 清理分片分配
    sm.currentShards = make(map[int]string)
}
```

### 4.4 健康检查和故障检测

```go
// HealthChecker 健康检查器
type HealthChecker struct {
    instanceManager *InstanceManager
    checkInterval   time.Duration
    timeout         time.Duration
    
    stopCh chan struct{}
    wg     sync.WaitGroup
}

func (hc *HealthChecker) Start() {
    hc.wg.Add(1)
    go hc.runHealthCheck()
}

func (hc *HealthChecker) runHealthCheck() {
    defer hc.wg.Done()
    
    ticker := time.NewTicker(hc.checkInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            hc.checkInstanceHealth()
        case <-hc.stopCh:
            return
        }
    }
}

func (hc *HealthChecker) checkInstanceHealth() {
    instances := hc.instanceManager.GetAllInstances()
    
    for _, instance := range instances {
        if hc.isInstanceHealthy(instance) {
            hc.instanceManager.UpdateInstanceStatus(instance.ID, InstanceStatusHealthy)
        } else {
            hc.instanceManager.UpdateInstanceStatus(instance.ID, InstanceStatusUnhealthy)
        }
    }
}

func (hc *HealthChecker) isInstanceHealthy(instance *ControllerInstanceInfo) bool {
    // 检查Lease是否过期
    if time.Since(instance.LastSeen) > hc.timeout {
        return false
    }
    
    // 可以添加更多健康检查逻辑
    // 例如：HTTP健康检查、TCP连接检查等
    
    return true
}
```

### 4.5 配置示例

```yaml
# 注册发现配置
instance:
  registry:
    type: "lease"  # 或 "configmap"
    lease:
      namespace: "kube-system"
      namePrefix: "sharded-controller"
      duration: "15s"
      renewInterval: "5s"
    configMap:
      name: "sharded-controller-instances"
      namespace: "default"
      updateInterval: "10s"
  
  healthCheck:
    interval: "10s"
    timeout: "30s"
    enabled: true
  
  shutdown:
    timeout: "60s"
    drainTimeout: "30s"
    graceful: true
```

### 4.6 重新分片机制

```go
// RebalancingManager 重新分片管理器
type RebalancingManager struct {
    shardingManager *ShardingManager
    instanceManager *InstanceManager
    stateManager    *StateManager
    
    // 重新分片阈值
    rebalanceThreshold float64
    
    // 重新分片间隔
    rebalanceInterval time.Duration
    
    // 停止信号
    stopCh chan struct{}
    wg     sync.WaitGroup
}

func (rm *RebalancingManager) Start() {
    rm.wg.Add(1)
    go rm.runRebalancing()
}

func (rm *RebalancingManager) runRebalancing() {
    defer rm.wg.Done()
    
    ticker := time.NewTicker(rm.rebalanceInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            rm.checkAndRebalance()
        case <-rm.stopCh:
            return
        }
    }
}

func (rm *RebalancingManager) checkAndRebalance() {
    // 检查是否需要重新分片
    if !rm.needsRebalancing() {
        return
    }
    
    // 获取当前controller实例列表
    instances := rm.instanceManager.GetHealthyInstances()
    
    // 执行重新分片
    newAssignment := rm.shardingManager.algorithm.Rebalance(
        rm.getInstanceIDs(instances), 
        rm.shardingManager.GetTotalShards(),
    )
    
    // 计算分片变化
    changes := rm.calculateShardChanges(newAssignment)
    
    // 通知分片变化
    rm.notifyShardChanges(changes)
    
    // 更新分片分配
    rm.shardingManager.UpdateShardAssignment(newAssignment)
}

func (rm *RebalancingManager) needsRebalancing() bool {
    // 检查是否有实例状态变化
    instances := rm.instanceManager.GetAllInstances()
    healthyCount := 0
    leavingCount := 0
    
    for _, instance := range instances {
        switch instance.Status {
        case InstanceStatusHealthy:
            healthyCount++
        case InstanceStatusLeaving:
            leavingCount++
        }
    }
    
    // 如果有实例正在退出，需要重新分片
    if leavingCount > 0 {
        return true
    }
    
    // 检查分片分配是否均衡
    return rm.isShardDistributionUnbalanced()
}

func (rm *RebalancingManager) isShardDistributionUnbalanced() bool {
    assignment := rm.shardingManager.GetShardAssignment()
    if len(assignment) == 0 {
        return false
    }
    
    // 计算分片分配的标准差
    shardCounts := make([]int, 0, len(assignment))
    for _, shards := range assignment {
        shardCounts = append(shardCounts, len(shards))
    }
    
    mean := float64(rm.shardingManager.GetTotalShards()) / float64(len(assignment))
    variance := 0.0
    
    for _, count := range shardCounts {
        diff := float64(count) - mean
        variance += diff * diff
    }
    variance /= float64(len(shardCounts))
    
    stdDev := math.Sqrt(variance)
    
    // 如果标准差超过阈值，认为分配不均衡
    return stdDev > rm.rebalanceThreshold
}

func (rm *RebalancingManager) calculateShardChanges(newAssignment map[string][]int) []ShardChange {
    oldAssignment := rm.shardingManager.GetShardAssignment()
    changes := make([]ShardChange, 0)
    
    // 检查分片转移
    for shardID := 0; shardID < rm.shardingManager.GetTotalShards(); shardID++ {
        oldInstance := oldAssignment[shardID]
        newInstance := newAssignment[shardID]
        
        if oldInstance != newInstance {
            changes = append(changes, ShardChange{
                ShardID:     shardID,
                OldInstance: oldInstance,
                NewInstance: newInstance,
                Type:        ShardChangeTypeReassigned,
            })
        }
    }
    
    return changes
}

func (rm *RebalancingManager) notifyShardChanges(changes []ShardChange) {
    for _, change := range changes {
        switch change.Type {
        case ShardChangeTypeReassigned:
            rm.shardingManager.NotifyShardReassigned(
                change.ShardID, 
                change.OldInstance, 
                change.NewInstance,
            )
        }
    }
}

func (rm *RebalancingManager) getInstanceIDs(instances []*ControllerInstanceInfo) []string {
    ids := make([]string, 0, len(instances))
    for _, instance := range instances {
        if instance.Status == InstanceStatusHealthy {
            ids = append(ids, instance.ID)
        }
    }
    return ids
}

// ShardChange 分片变化信息
type ShardChange struct {
    ShardID     int
    OldInstance string
    NewInstance string
    Type        ShardChangeType
}

// ShardChangeType 分片变化类型
type ShardChangeType string

const (
    ShardChangeTypeGained     ShardChangeType = "Gained"
    ShardChangeTypeLost       ShardChangeType = "Lost"
    ShardChangeTypeReassigned ShardChangeType = "Reassigned"
)
```

### 4.7 状态同步

```go
// StateSynchronizer 状态同步器
type StateSynchronizer struct {
    stateStore StateStore
    shardingManager *ShardingManager
    syncInterval time.Duration
    
    stopCh chan struct{}
    wg     sync.WaitGroup
}

func (ss *StateSynchronizer) Start() {
    ss.wg.Add(1)
    go ss.runStateSync()
}

func (ss *StateSynchronizer) runStateSync() {
    defer ss.wg.Done()
    
    ticker := time.NewTicker(ss.syncInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            ss.syncState()
        case <-ss.stopCh:
            return
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
    
    // 同步实例状态
    ss.syncInstanceState()
}

func (ss *StateSynchronizer) syncInstanceState() {
    instances := ss.shardingManager.instanceManager.GetAllInstances()
    
    for _, instance := range instances {
        instanceState := &InstanceState{
            ID:        instance.ID,
            Name:      instance.Name,
            Status:    instance.Status,
            Shards:    instance.Shards,
            LastSeen:  instance.LastSeen,
            PodName:   instance.PodName,
            Namespace: instance.Namespace,
        }
        
        key := fmt.Sprintf("instance-%s", instance.ID)
        err := ss.stateStore.SaveState(key, instanceState)
        if err != nil {
            log.Errorf("Failed to save instance state for %s: %v", instance.ID, err)
        }
    }
}

// ShardState 分片状态
type ShardState struct {
    Assignment map[int]string `json:"assignment"`
    Timestamp  time.Time      `json:"timestamp"`
    Version    int64          `json:"version"`
}

// InstanceState 实例状态
type InstanceState struct {
    ID        string         `json:"id"`
    Name      string         `json:"name"`
    Status    InstanceStatus `json:"status"`
    Shards    []int          `json:"shards"`
    LastSeen  time.Time      `json:"last_seen"`
    PodName   string         `json:"pod_name"`
    Namespace string         `json:"namespace"`
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

func (c *CustomShardingAlgorithm) Rebalance(instances []string, totalShards int) map[string][]int {
    // 实现自定义重新分片逻辑
    assignment := make(map[string][]int)
    
    // 平均分配分片
    shardsPerInstance := totalShards / len(instances)
    remainder := totalShards % len(instances)
    
    shardIndex := 0
    for i, instance := range instances {
        shardCount := shardsPerInstance
        if i < remainder {
            shardCount++
        }
        
        for j := 0; j < shardCount; j++ {
            assignment[instance] = append(assignment[instance], shardIndex)
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
    
    // controller实例相关指标
    InstanceCount     prometheus.Gauge
    InstanceHealth    prometheus.Gauge
    
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
        InstanceCount: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "sharded_controller_instance_count",
            Help: "Number of controller instances",
        }),
        // ... 其他指标
    }
    
    registry.MustRegister(
        metrics.ShardCount,
        metrics.ShardRebalances,
        metrics.InstanceCount,
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

func (cl *ControllerLogger) LogInstanceHealth(instanceID string, status InstanceStatus) {
    cl.logger.Info("Controller instance health status changed",
        zap.String("instance_id", instanceID),
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

instance:
  healthCheckInterval: "10s"
  healthCheckTimeout: "5s"
  instanceTimeout: "60s"
  controllerName: "my-sharded-controller"
  namespace: "default"

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
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
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
    instances := []string{"instance1", "instance2", "instance3"}
    assignment := algorithm.Rebalance(instances, 10)
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

1. **水平扩展**: 支持动态增加controller实例
2. **垂直扩展**: 支持增加单个实例的处理能力
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

1. **健康检查**: 定期检查controller实例健康状态
2. **超时处理**: 设置合理的超时时间
3. **重试机制**: 实现指数退避重试

### 11.2 故障恢复

1. **自动恢复**: 自动处理临时故障
2. **手动干预**: 提供手动恢复工具
3. **回滚机制**: 支持配置回滚

## 12. 总结

这个分片框架设计提供了：

1. **完整的抽象**: 通过接口抽象分片算法和业务逻辑
2. **高可用性**: 支持controller实例故障自动恢复
3. **可扩展性**: 支持动态扩缩容
4. **可观测性**: 提供完整的监控和日志
5. **易用性**: 提供简单的API和配置

通过这个框架，业务方可以专注于实现具体的业务逻辑，而分片、controller实例管理、状态同步等复杂问题都由框架统一处理。 
