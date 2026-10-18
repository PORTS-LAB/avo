//! Minimal flattened device tree (DTB) writer, version 17.

use std::collections::HashMap;

pub struct Fdt {
    structure: Vec<u8>,
    strings: Vec<u8>,
    offsets: HashMap<String, u32>,
    depth: usize,
}

pub enum Value<'a> {
    Empty,
    U32(u32),
    Cells(&'a [u32]),
    Str(&'a str),
    Strs(&'a [&'a str]),
}

const BEGIN_NODE: u32 = 1;
const END_NODE: u32 = 2;
const PROP: u32 = 3;
const END: u32 = 9;

impl Fdt {
    pub fn new() -> Fdt {
        Fdt { structure: Vec::new(), strings: Vec::new(), offsets: HashMap::new(), depth: 0 }
    }

    fn token(&mut self, token: u32) {
        self.structure.extend_from_slice(&token.to_be_bytes());
    }

    fn pad(&mut self) {
        while self.structure.len() % 4 != 0 {
            self.structure.push(0);
        }
    }

    pub fn begin(&mut self, name: &str) {
        self.token(BEGIN_NODE);
        self.structure.extend_from_slice(name.as_bytes());
        self.structure.push(0);
        self.pad();
        self.depth += 1;
    }

    pub fn end(&mut self) {
        self.token(END_NODE);
        self.depth -= 1;
    }

    pub fn prop(&mut self, name: &str, value: Value) {
        let data: Vec<u8> = match value {
            Value::Empty => Vec::new(),
            Value::U32(v) => v.to_be_bytes().to_vec(),
            Value::Cells(cells) => cells.iter().flat_map(|c| c.to_be_bytes()).collect(),
            Value::Str(s) => [s.as_bytes(), &[0]].concat(),
            Value::Strs(list) => list.iter().flat_map(|s| [s.as_bytes(), &[0]].concat()).collect(),
        };
        let offset = match self.offsets.get(name) {
            Some(offset) => *offset,
            None => {
                let offset = self.strings.len() as u32;
                self.strings.extend_from_slice(name.as_bytes());
                self.strings.push(0);
                self.offsets.insert(name.to_string(), offset);
                offset
            }
        };
        self.token(PROP);
        self.structure.extend_from_slice(&(data.len() as u32).to_be_bytes());
        self.structure.extend_from_slice(&offset.to_be_bytes());
        self.structure.extend_from_slice(&data);
        self.pad();
    }

    pub fn finish(mut self) -> Vec<u8> {
        assert_eq!(self.depth, 0, "unbalanced nodes");
        self.token(END);
        let header_len = 40u32;
        let reserve_len = 16u32; // one empty memory reservation entry
        let struct_offset = header_len + reserve_len;
        let strings_offset = struct_offset + self.structure.len() as u32;
        let total = strings_offset + self.strings.len() as u32;
        let mut out = Vec::with_capacity(total as usize);
        for value in [
            0xd00d_feed,
            total,
            struct_offset,
            strings_offset,
            header_len,
            17,
            16,
            0,
            self.strings.len() as u32,
            self.structure.len() as u32,
        ] {
            out.extend_from_slice(&u32::to_be_bytes(value));
        }
        out.extend_from_slice(&[0; 16]);
        out.extend_from_slice(&self.structure);
        out.extend_from_slice(&self.strings);
        out
    }
}
