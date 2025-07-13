use std::{fs, sync::Arc};

use anyhow::Result;
use interprocess::local_socket::{
    tokio::{prelude::*, Stream, Listener},
    GenericNamespaced, ListenerOptions,
};
use sui_json_rpc_types::SuiEvent;
use sui_types::effects::TransactionEffects;
use tokio::{io::AsyncWriteExt, sync::{Mutex, mpsc}, task::JoinHandle};

pub const TX_SOCKET_PATH: &str = "/tmp/sui/sui_tx.sock";

#[derive(Debug)]
struct BroadcastMessage {
    effects: TransactionEffects,
    events: Vec<SuiEvent>,
}

/// A handler that manages connections with external clients over a Unix socket
/// and broadcasts transaction data to them.
///
/// It spawns a background task upon creation to accept new client connections.
pub struct TxHandler {
    path: String,
    conns: Arc<Mutex<Vec<Stream>>>,
    // Message queue sender
    tx_sender: mpsc::UnboundedSender<BroadcastMessage>,
    // Background task handle
    _broadcast_task: JoinHandle<()>,
}

impl Default for TxHandler {
    fn default() -> Self {
        Self::new(TX_SOCKET_PATH)
    }
}

impl Drop for TxHandler {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

impl TxHandler {
    pub fn new(path: &str) -> Self {
        let _ = fs::remove_file(path);

        let name = path
            .to_ns_name::<GenericNamespaced>()
            .expect("Invalid tx socket path");
        let opts = ListenerOptions::new().name(name);
        let listener = opts.create_tokio().expect("Failed to bind tx socket");
        let conns = Arc::new(Mutex::new(vec![]));

        // Create message queue
        let (tx_sender, tx_receiver) = mpsc::unbounded_channel::<BroadcastMessage>();

        // Start connection accept task
        let conns_for_accept = conns.clone();
        tokio::spawn(async move {
            Self::accept_connections_loop(listener, conns_for_accept).await;
        });

        // Start broadcast task
        let conns_for_broadcast = conns.clone();
        let broadcast_task = tokio::spawn(async move {
            Self::broadcast_loop(tx_receiver, conns_for_broadcast).await;
        });

        Self {
            path: path.to_string(),
            conns,
            tx_sender,
            _broadcast_task: broadcast_task,
        }
    }

    /// Queue message for broadcast
    pub async fn queue_for_broadcast(
        &self,
        effects: TransactionEffects,
        events: Vec<SuiEvent>
    ) -> Result<()> {
        let message = BroadcastMessage {
            effects,
            events,
        };
        
        self.tx_sender.send(message)
            .map_err(|_| anyhow::anyhow!("Broadcast task has stopped"))?;
        
        Ok(())
    }

    /// Sends the transaction effects and a list of events to all connected clients.
    ///
    /// This function sends data over the Unix socket using a specific binary protocol.
    /// The data packet is structured as follows:
    /// 1. Length of the effects data (4 bytes, Big Endian u32).
    /// 2. The `TransactionEffects` data, serialized using `bincode`.
    /// 3. Length of the events data (4 bytes, Big Endian u32).
    /// 4. The `Vec<SuiEvent>` data, serialized into a JSON array using `serde_json`.
    ///
    /// This function will also prune any connections that have been disconnected.
    /// Maintain compatibility: directly calls queue_for_broadcast
    pub async fn send_tx_effects_and_events(
        &self,
        effects: &TransactionEffects,
        events: Vec<SuiEvent>,
    ) -> Result<()> {
        self.queue_for_broadcast(effects.clone(), events).await
    }

    /// Connection accept loop
    async fn accept_connections_loop(
        listener: Listener,
        connections: Arc<Mutex<Vec<Stream>>>,
    ) {
        loop {
            let conn = match listener.accept().await {
                Ok(c) => c,
                _err => {
                    continue;
                }
            };

            connections.lock().await.push(conn);
        }
    }

    /// Broadcast task loop
    async fn broadcast_loop(
        mut receiver: mpsc::UnboundedReceiver<BroadcastMessage>,
        connections: Arc<Mutex<Vec<Stream>>>,
    ) {
        while let Some(message) = receiver.recv().await {
            Self::send_to_all_connections(&message, &connections).await;
        }
    }

    /// Send message to all connections
    async fn send_to_all_connections(
        message: &BroadcastMessage,
        connections: &Arc<Mutex<Vec<Stream>>>,
    ) {
        // Serialize data
        let effects_bytes = match bincode::serialize(&message.effects) {
            Ok(bytes) => bytes,
            Err(_) => return, // Serialization failed, skip this message
        };
        
        let events_bytes = match serde_json::to_vec(&message.events) {
            Ok(bytes) => bytes,
            Err(_) => return, // Serialization failed, skip this message
        };

        let effects_len_bytes = (effects_bytes.len() as u32).to_be_bytes();
        let events_len_bytes = (events_bytes.len() as u32).to_be_bytes();

        let mut conns = connections.lock().await;
        let mut active_conns = Vec::new();

        // Process connections one by one, remove invalid connections
        while let Some(mut conn) = conns.pop() {
            let result = Self::send_to_connection(
                &mut conn,
                &effects_len_bytes,
                &effects_bytes,
                &events_len_bytes,
                &events_bytes,
            ).await;

            if result.is_ok() {
                active_conns.push(conn);
            }
        }

        *conns = active_conns;
    }

    /// Send message to a single connection
    async fn send_to_connection(
        conn: &mut Stream,
        effects_len_bytes: &[u8; 4],
        effects_bytes: &[u8],
        events_len_bytes: &[u8; 4],
        events_bytes: &[u8],
    ) -> Result<()> {
        conn.write_all(effects_len_bytes).await?;
        conn.write_all(effects_bytes).await?;
        conn.write_all(events_len_bytes).await?;
        conn.write_all(events_bytes).await?;
        Ok(())
    }

    /// Get current connection count
    pub fn connection_count(&self) -> usize {
        // Note: use try_lock to avoid blocking
        self.conns.try_lock().map(|c| c.len()).unwrap_or(0)
    }
}
