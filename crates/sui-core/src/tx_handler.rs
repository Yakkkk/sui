use std::{fs, sync::Arc};

use anyhow::Result;
use interprocess::local_socket::{
    tokio::{prelude::*, Stream},
    GenericNamespaced, ListenerOptions,
};
use sui_json_rpc_types::SuiEvent;
use sui_types::effects::TransactionEffects;
use tokio::{io::AsyncWriteExt, sync::Mutex};

pub const TX_SOCKET_PATH: &str = "/tmp/sui/sui_tx.sock";

#[derive(Clone)]
/// A handler that manages connections with external clients over a Unix socket
/// and broadcasts transaction data to them.
///
/// It spawns a background task upon creation to accept new client connections.
pub struct TxHandler {
    path: String,
    conns: Arc<Mutex<Vec<Stream>>>,
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
        let conns_clone = conns.clone();

        tokio::spawn(async move {
            loop {
                let conn = match listener.accept().await {
                    Ok(c) => c,
                    _err => {
                        continue;
                    }
                };

                conns_clone.lock().await.push(conn);
            }
        });

        Self {
            path: path.to_string(),
            conns,
        }
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
    pub async fn send_tx_effects_and_events(
        &self,
        effects: &TransactionEffects,
        events: Vec<SuiEvent>,
    ) -> Result<()> {
        // Serialize effects and events separately
        let effects_bytes = bincode::serialize(effects)?;
        let events_bytes = serde_json::to_vec(&events)?;

        // Get lengths as BE bytes
        let effects_len_bytes = (effects_bytes.len() as u32).to_be_bytes();
        let events_len_bytes = (events_bytes.len() as u32).to_be_bytes();

        let mut conns = self.conns.lock().await;
        let mut active_conns = Vec::new();

        while let Some(mut conn) = conns.pop() {
            let result: Result<()> = async {
                // Write effects length and data
                conn.write_all(&effects_len_bytes).await?;
                conn.write_all(&effects_bytes).await?;

                // Write events length and data
                conn.write_all(&events_len_bytes).await?;
                conn.write_all(&events_bytes).await?;
                Ok(())
            }
            .await;

            if result.is_ok() {
                active_conns.push(conn);
            }
        }

        *conns = active_conns;

        Ok(())
    }
}
