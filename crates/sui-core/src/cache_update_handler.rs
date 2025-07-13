use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use anyhow::Result;
use sui_types::base_types::ObjectID;
use sui_types::object::Object;
use tokio::io::AsyncWriteExt;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;

use tracing::{error, info, warn};

const SOCKET_PATH: &str = "/tmp/sui/sui_cache_updates.sock";

#[derive(Debug)]
struct CacheBroadcastMessage {
    objects: Vec<(ObjectID, Object)>,
}

/// A handler for managing connections with external cache update clients.
///
/// When it detects that objects related to DeFi protocols or other specific addresses
/// have been modified, it pushes the updated object data to clients via a Unix socket.
#[derive(Debug)]
pub struct CacheUpdateHandler {
    socket_path: PathBuf,
    connections: Arc<Mutex<Vec<UnixStream>>>,
    running: Arc<AtomicBool>,
    // Message queue sender
    tx_sender: mpsc::UnboundedSender<CacheBroadcastMessage>,
    // Background task handle
    _broadcast_task: JoinHandle<()>,
}

impl CacheUpdateHandler {
    /// Check if a socket path is already in use by attempting to connect to it
    fn is_socket_in_use(socket_path: &PathBuf) -> bool {
        if !socket_path.exists() {
            return false;
        }
        
        // Try to connect to see if someone is listening
        match std::os::unix::net::UnixStream::connect(socket_path) {
            Ok(_) => {
                // Someone is listening on this socket
                true
            }
            Err(_) => {
                // No one is listening, it's a stale socket file
                false
            }
        }
    }

    pub fn new() -> Self {
        let socket_path = PathBuf::from(SOCKET_PATH);
        
        // Ensure the parent directory exists
        if let Some(parent_dir) = socket_path.parent() {
            if let Err(e) = std::fs::create_dir_all(parent_dir) {
                error!("Failed to create socket directory {:?}: {}", parent_dir, e);
            }
        }
        
        // Check if socket is already in use
        if Self::is_socket_in_use(&socket_path) {
            panic!("Socket {:?} is already in use by another process", socket_path);
        }
        
        // Remove stale socket file if it exists but no one is listening
        if socket_path.exists() {
            info!("Removing stale socket file: {:?}", socket_path);
            if let Err(e) = std::fs::remove_file(&socket_path) {
                warn!("Failed to remove stale socket file {:?}: {}", socket_path, e);
            }
        }
        
        // Now try to bind
        let listener = UnixListener::bind(&socket_path).unwrap_or_else(|e| {
            panic!("Failed to bind Unix socket at {:?}: {}", socket_path, e);
        });
        
        info!("Successfully bound Unix socket at {:?}", socket_path);

        let connections = Arc::new(Mutex::new(Vec::new()));
        let running = Arc::new(AtomicBool::new(true));

        // Create message queue
        let (tx_sender, tx_receiver) = mpsc::unbounded_channel::<CacheBroadcastMessage>();

        // Start connection accept task
        let connections_for_accept = connections.clone();
        let running_for_accept = running.clone();
        tokio::spawn(async move {
            Self::accept_connections_loop(listener, connections_for_accept, running_for_accept).await;
        });

        // Start broadcast task
        let connections_for_broadcast = connections.clone();
        let broadcast_task = tokio::spawn(async move {
            Self::broadcast_loop(tx_receiver, connections_for_broadcast).await;
        });

        Self {
            socket_path,
            connections,
            running,
            tx_sender,
            _broadcast_task: broadcast_task,
        }
    }

    /// Queue message for broadcast
    pub async fn queue_for_broadcast(&self, objects: Vec<(ObjectID, Object)>) -> Result<()> {
        let message = CacheBroadcastMessage {
            objects,
        };
        
        self.tx_sender.send(message)
            .map_err(|_| anyhow::anyhow!("Broadcast task has stopped"))?;
        
        Ok(())
    }

    /// Notifies all connected clients of a set of object updates.
    ///
    /// This function sends a binary stream over the Unix socket with the following structure:
    /// 1. Total length of the serialized object list data (4 bytes, Little Endian u32).
    /// 2. The list of objects (`Vec<(ObjectID, Object)>`), serialized using `bcs`.
    /// Maintain compatibility: directly calls queue_for_broadcast
    pub async fn notify_written(&self, objects: Vec<(ObjectID, Object)>) {
        let _ = self.queue_for_broadcast(objects).await;
    }

    /// Connection accept loop
    async fn accept_connections_loop(
        listener: UnixListener,
        connections: Arc<Mutex<Vec<UnixStream>>>,
        running: Arc<AtomicBool>,
    ) {
        while running.load(Ordering::SeqCst) {
            match listener.accept().await {
                Ok((stream, _addr)) => {
                    info!("New client connected to cache update socket");
                    let mut connections = connections.lock().await;
                    connections.push(stream);
                }
                Err(e) => {
                    error!("Error accepting connection: {}", e);
                }
            }
        }
    }

    /// Broadcast task loop
    async fn broadcast_loop(
        mut receiver: mpsc::UnboundedReceiver<CacheBroadcastMessage>,
        connections: Arc<Mutex<Vec<UnixStream>>>,
    ) {
        while let Some(message) = receiver.recv().await {
            Self::send_to_all_connections(&message, &connections).await;
        }
    }

    /// Send message to all connections
    async fn send_to_all_connections(
        message: &CacheBroadcastMessage,
        connections: &Arc<Mutex<Vec<UnixStream>>>,
    ) {
        // Serialize data
        let serialized = match bcs::to_bytes(&message.objects) {
            Ok(bytes) => bytes,
            Err(_) => return, // Serialization failed, skip this message
        };
        
        let len = serialized.len() as u32;
        let len_bytes = len.to_le_bytes();

        let mut conns = connections.lock().await;
        let mut active_conns = Vec::new();

        // Process connections one by one, remove invalid connections
        while let Some(mut conn) = conns.pop() {
            let result = Self::send_to_connection(&mut conn, &len_bytes, &serialized).await;
            if result.is_ok() {
                active_conns.push(conn);
            }
        }

        *conns = active_conns;
    }

    /// Send message to a single connection
    async fn send_to_connection(
        conn: &mut UnixStream,
        len_bytes: &[u8; 4],
        serialized: &[u8],
    ) -> Result<()> {
        conn.write_all(len_bytes).await?;
        conn.write_all(serialized).await?;
        Ok(())
    }

    /// Get current connection count
    pub fn connection_count(&self) -> usize {
        // Note: use try_lock to avoid blocking
        self.connections.try_lock().map(|c| c.len()).unwrap_or(0)
    }
}

impl Default for CacheUpdateHandler {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for CacheUpdateHandler {
    fn drop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        
        // Only remove socket file if it exists and we can verify it's ours
        if self.socket_path.exists() {
            if let Err(e) = std::fs::remove_file(&self.socket_path) {
                error!("Failed to remove socket file {:?} during cleanup: {}", self.socket_path, e);
            } else {
                info!("Successfully removed socket file {:?} during cleanup", self.socket_path);
            }
        }
    }
}
